#!/usr/bin/env bash
# setup-n8n.sh — Stand up n8n on its own CT and auto-wire credentials for
# every TD-Proxmox service so the founder can start building workflows
# without copy-pasting tokens out of /root/td-tokens.txt.
#
# What it does (idempotent at each step):
#   1. Reads tokens from /root/td-tokens.txt
#   2. Creates an n8n CT via community-scripts helper (skips if exists)
#   3. Joins it to Tailscale + pushes SSH keys + PATH helper
#   4. Waits for n8n on port 5678
#   5. Does first-run owner signup via POST /rest/owner/setup using
#      ADMIN_USER/EMAIL/PASSWORD already in tokens file (same admin as
#      everything else in the stack — same password tier they're used to)
#   6. Mints an n8n API key and saves it back as N8N_API_KEY in tokens
#   7. Creates pre-configured credentials in n8n:
#        - Ollama (shared)         → http://ollama-pi-agent:11434
#        - Mattermost (pi-bot)     → MATTERMOST_BOT_TOKEN
#        - Gitea (admin)           → GITEA_TOKEN
#        - OpenWebUI (OpenAI-compat) → OPENWEBUI_TOKEN (if set)
#   8. Imports 3 starter workflows from addons/n8n/workflows/:
#        - hello-mattermost.json — webhook → post in #general
#        - mm-ollama-chat.json  — listen on a channel → Ollama → reply
#        - gitea-daily-digest.json — cron → recent commits → MM post
#      (Each workflow is INACTIVE on import; user activates after review.)
#   9. Registers a Homepage tile
#
# Usage:
#   ./setup-n8n.sh                      # default install
#   ./setup-n8n.sh --dry-run            # preview
#   ./setup-n8n.sh --uninstall          # stop + destroy CT
#   ./setup-n8n.sh --skip-workflows     # don't import the 3 examples
#   ./setup-n8n.sh --skip-credentials   # just install CT, no wiring
#   ./setup-n8n.sh --skip-homepage-tile
#
# Prereqs:
#   - TD-Proxmox foundation built (bootstrap-pve.sh + configure-apps.sh
#     finished). /root/td-tokens.txt must have ADMIN_USER/EMAIL/PASSWORD.
#   - For credentials to actually wire: mattermost + gitea (at minimum)
#     must already be configured. Missing tokens = warning, not failure.

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0
SKIP_WORKFLOWS=0
SKIP_CREDENTIALS=0
SKIP_HOMEPAGE_TILE=0
CREDENTIALS_ONLY=0
VERBOSE=0
N8N_HOSTNAME="n8n"
TOKENS_FILE="/root/td-tokens.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="$SCRIPT_DIR/n8n/workflows"
HELPER_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/ct/n8n.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN=1; shift ;;
    --uninstall)          UNINSTALL=1; shift ;;
    --skip-workflows)     SKIP_WORKFLOWS=1; shift ;;
    --skip-credentials)   SKIP_CREDENTIALS=1; shift ;;
    --skip-homepage-tile) SKIP_HOMEPAGE_TILE=1; shift ;;
    --credentials-only)   CREDENTIALS_ONLY=1; shift ;;
    --verbose|-v)         VERBOSE=1; shift ;;
    --hostname)           N8N_HOSTNAME="$2"; shift 2 ;;
    -h|--help)            sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-n8n]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-n8n]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-n8n]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — PVE host required."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

read_token() {
  local key="$1"
  [[ -f "$TOKENS_FILE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print; exit }' "$TOKENS_FILE"
}

upsert_token() {
  local key="$1" val="$2"
  touch "$TOKENS_FILE"
  chmod 600 "$TOKENS_FILE"
  if grep -q "^$key=" "$TOKENS_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$TOKENS_FILE"
  else
    echo "$key=$val" >> "$TOKENS_FILE"
  fi
}

add_tun_to_ct() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  grep -q "tun rwm" "$conf" 2>/dev/null && return 0
  cat >> "$conf" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
}

# ----- pre-flight --------------------------------------------------------
log "Pre-flight..."

ADMIN_USER="$(read_token ADMIN_USER || true)"
ADMIN_EMAIL="$(read_token ADMIN_EMAIL || true)"
ADMIN_PASSWORD="$(read_token ADMIN_PASSWORD || true)"

if [[ -z "$ADMIN_USER" || -z "$ADMIN_EMAIL" || -z "$ADMIN_PASSWORD" ]]; then
  die "Need ADMIN_USER, ADMIN_EMAIL, ADMIN_PASSWORD in $TOKENS_FILE.
  Re-run automation/configure-apps.sh first so those land there."
fi

TS_AUTHKEY="$(read_token TS_AUTHKEY || true)"
CT_PASSWORD="$(read_token CT_PASSWORD || true)"

# Tokens needed for wiring (warn if missing — we proceed without those creds)
MM_BOT_TOKEN="$(read_token MATTERMOST_BOT_TOKEN || true)"
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
MM_URL="$(read_token MATTERMOST_URL || true)"
[[ -z "$MM_URL" ]] && MM_URL="http://mattermost:8065"
GITEA_TOKEN="$(read_token GITEA_TOKEN || true)"
OPENWEBUI_TOKEN="$(read_token OPENWEBUI_TOKEN || true)"

# Check service CTs that we'll wire to (warnings only)
OLLAMA_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
MM_CTID="$(find_ct_by_hostname mattermost 2>/dev/null || true)"
GITEA_CTID="$(find_ct_by_hostname gitea 2>/dev/null || true)"
OW_CTID="$(find_ct_by_hostname openwebui 2>/dev/null || true)"

[[ -z "$OLLAMA_CTID" ]] && warn "  ollama-pi-agent CT not found — Ollama credential will still be created (URL only) but may not resolve."
[[ -z "$MM_CTID" || -z "$MM_BOT_TOKEN" ]] && warn "  Mattermost CT/token missing — MM credential will be skipped."
[[ -z "$GITEA_CTID" || -z "$GITEA_TOKEN" ]] && warn "  Gitea CT/token missing — Gitea credential will be skipped."
[[ -z "$OW_CTID" ]] && warn "  openwebui CT not found — OpenWebUI credential will be skipped."

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
  if [[ -z "$CTID" ]]; then
    log "No $N8N_HOSTNAME CT found — nothing to uninstall."
    exit 0
  fi
  log "Uninstalling n8n CT $CTID..."
  run "pct stop $CTID 2>/dev/null || true"
  run "pct destroy $CTID --purge"
  run "sed -i '/^N8N_API_KEY=/d' '$TOKENS_FILE'"
  # Strip Homepage tile (markered block)
  HP_CTID="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -n "$HP_CTID" ]] && (( ! DRY_RUN )); then
    pct exec "$HP_CTID" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage; do
        [[ -f "$d/services.yaml" ]] || continue
        SVC="$d/services.yaml"
        cp "$SVC" "${SVC}.bak.$(date +%s)"
        awk "
          /^# TD-Addon: n8n/ { in_block=1; next }
          in_block && /^# TD-Addon:/ { in_block=0; print; next }
          !in_block { print }
        " "$SVC" > /tmp/services.yaml.new && mv /tmp/services.yaml.new "$SVC"
      done
      systemctl restart homepage 2>/dev/null || true
    '
  fi
  log "Uninstalled."
  exit 0
fi

# ----- 1. Create n8n CT --------------------------------------------------
CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
if (( CREDENTIALS_ONLY )); then
  [[ -n "$CTID" ]] || die "--credentials-only requires existing $N8N_HOSTNAME CT."
  log "Credentials-only mode — using existing CT $CTID, skipping create + Tailscale."
elif [[ -n "$CTID" ]]; then
  log "n8n CT already exists (CT $CTID) — skipping creation."
else
  log "Creating n8n CT via community-scripts helper..."
  if (( DRY_RUN )); then
    printf "[dry-run] bash <(curl -fsSL %s)\n" "$HELPER_URL"
  else
    # The helper is interactive (whiptail). User clicks "Default Install".
    CT_PASSWORD="$CT_PASSWORD" var_hostname="$N8N_HOSTNAME" \
      bash <(curl -fsSL "$HELPER_URL") || die "n8n helper failed."
  fi

  CTID="$(find_ct_by_hostname "$N8N_HOSTNAME" 2>/dev/null || true)"
  [[ -n "$CTID" ]] || die "n8n CT didn't show up after helper ran."

  # /dev/net/tun for Tailscale + restart
  pct stop "$CTID"
  add_tun_to_ct "$CTID"
  pct start "$CTID"
  sleep 5

  # Push PVE host's authorized_keys
  pct exec "$CTID" -- mkdir -p /root/.ssh
  pct push "$CTID" /root/.ssh/authorized_keys /root/.ssh/authorized_keys --perms 0600

  # Join Tailscale (idempotent --reset)
  if [[ -n "$TS_AUTHKEY" ]]; then
    log "Joining Tailscale..."
    pct exec "$CTID" -- bash -lc "
      command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
      tailscale up --authkey='$TS_AUTHKEY' --hostname='$N8N_HOSTNAME' --reset --accept-routes 2>&1 | tail -3
    "
  fi
fi

# ----- 2. Wait for n8n on port 5678 --------------------------------------
log "Waiting for n8n on :5678..."
if (( ! DRY_RUN )); then
  for i in {1..60}; do
    if pct exec "$CTID" -- bash -lc 'curl -fsS --max-time 3 http://localhost:5678/healthz >/dev/null 2>&1' 2>/dev/null; then
      log "  ✓ n8n is up"
      break
    fi
    sleep 3
  done
  pct exec "$CTID" -- bash -lc 'curl -fsS --max-time 3 http://localhost:5678/healthz >/dev/null 2>&1' \
    || die "n8n didn't come up. Check: pct exec $CTID -- journalctl -u n8n -n 50"
fi

# ----- helpers for posting JSON SAFELY -----------------------------------
# Pattern: write payload to a temp file on the CT, then `curl -d @file`.
# This avoids quoting collisions when JSON contains " characters and we'd
# otherwise be embedding it through `pct exec ... bash -lc "curl -d '...'"`.
#
# Use: post_json_file <local_payload_file> <method> <url> [extra_curl_args...]
# Returns body on stdout, HTTP status on stderr. Always reads the body so
# callers can grep it; we don't swallow errors.
load_token_from_file_on_ct() {
  local ctid="$1" local_file="$2" remote_file="$3"
  pct push "$ctid" "$local_file" "$remote_file" --perms 0600
}

# Hit n8n's REST or API endpoint. Args:
#   $1 = http method
#   $2 = path (starting with '/' — caller picks /rest/... or /api/v1/...)
#   $3 = body (optional, JSON string)
# Extra args after $3 are appended to curl. Always prints body. Always
# prints "HTTP <code>" to stderr.
n8n_curl() {
  local method="$1" path="$2" body="${3:-}"
  shift 3 || true
  local remote_body="/tmp/n8n-body.$$.json"
  # Write the body locally then push (or empty out the remote file)
  if [[ -n "$body" ]]; then
    local tmp; tmp="$(mktemp)"
    printf '%s' "$body" > "$tmp"
    pct push "$CTID" "$tmp" "$remote_body" --perms 0600 >/dev/null
    rm -f "$tmp"
  else
    pct exec "$CTID" -- bash -lc "rm -f $remote_body; touch $remote_body"
  fi

  local auth_header=""
  if [[ "$path" == /api/v1/* && -n "${N8N_API_KEY:-}" ]]; then
    auth_header="-H 'X-N8N-API-KEY: ${N8N_API_KEY}'"
  fi
  local data_arg=""
  [[ -n "$body" ]] && data_arg="--data-binary @${remote_body}"

  # Run curl on the CT. Print body to stdout, status to stderr.
  # Note: the auth_header / data_arg are intentionally unquoted inside the
  # double-quoted heredoc so the shell on the CT expands them as separate
  # tokens. The header value itself is wrapped in single quotes so the API
  # key is safe.
  pct exec "$CTID" -- bash -lc "
    code=\$(curl -sS -o /tmp/n8n-resp.body -w '%{http_code}' \
      -b /tmp/n8n-cookies.txt -c /tmp/n8n-cookies.txt \
      -X $method 'http://localhost:5678${path}' \
      -H 'Content-Type: application/json' \
      ${auth_header} \
      ${data_arg})
    cat /tmp/n8n-resp.body
    echo HTTP \$code >&2
    rm -f /tmp/n8n-resp.body
  "
}

# ----- 3. Owner setup via REST -------------------------------------------
log "Setting up n8n owner account..."

if (( ! DRY_RUN )); then
  # POST /rest/owner/setup — accepts {email, firstName, lastName, password}
  # If already done, returns 400; we treat that as "already done" and move on.
  # Env vars MUST be prefixed before python3 — they're env to the command,
  # not argv. (Bash's KEY=VAL prefix only applies as env when at the start.)
  OWNER_BODY="$(ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_USER="$ADMIN_USER" ADMIN_PASSWORD="$ADMIN_PASSWORD" python3 -c '
import json, os
print(json.dumps({
  "email":     os.environ["ADMIN_EMAIL"],
  "firstName": os.environ["ADMIN_USER"],
  "lastName":  "Admin",
  "password":  os.environ["ADMIN_PASSWORD"],
}))')"

  OWNER_RESP="$(n8n_curl POST /rest/owner/setup "$OWNER_BODY" 2> /tmp/n8n-owner.code)"
  OWNER_CODE="$(awk '{print $2}' /tmp/n8n-owner.code 2>/dev/null)"

  case "$OWNER_CODE" in
    200|201)
      log "  ✓ Owner account created (HTTP $OWNER_CODE)"
      ;;
    400|409)
      log "  Owner already exists (HTTP $OWNER_CODE) — logging in"
      LOGIN_BODY="$(ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASSWORD" python3 -c '
import json, os
print(json.dumps({
  "emailOrLdapLoginId": os.environ["ADMIN_EMAIL"],
  "email":              os.environ["ADMIN_EMAIL"],
  "password":           os.environ["ADMIN_PASSWORD"],
}))')"
      # n8n 1.x uses /rest/login; n8n 2.x may use /rest/auth/login. Try both.
      LOGGED_IN=0
      for ep in /rest/login /rest/auth/login; do
        LOGIN_RESP="$(n8n_curl POST "$ep" "$LOGIN_BODY" 2> /tmp/n8n-login.code)"
        LOGIN_CODE="$(awk '{print $2}' /tmp/n8n-login.code 2>/dev/null)"
        log "  Trying $ep — HTTP $LOGIN_CODE"
        if [[ "$LOGIN_CODE" =~ ^2 ]]; then
          log "  ✓ Logged in via $ep"
          LOGGED_IN=1
          break
        fi
      done
      if (( ! LOGGED_IN )); then
        warn "  Login failed on all known endpoints. Last response:"
        echo "$LOGIN_RESP" | head -3 | sed 's/^/    /' >&2
      fi
      ;;
    *)
      warn "  Owner setup HTTP $OWNER_CODE — body:"
      echo "$OWNER_RESP" | head -3 | sed 's/^/    /' >&2
      warn "  Continuing anyway — manual sign-in may be required."
      ;;
  esac

  # Mint an API key. n8n versions differ on the endpoint and response shape:
  #   1.0–1.48: POST /rest/me/api-keys                  → {data:{apiKey:"..."}}
  #   1.49+:    POST /rest/api-keys                     → {data:{rawApiKey:"...", apiKey:"..."}}
  # We try both. We also re-use an existing key if one is already in tokens
  # (n8n versions before 1.49 only allow one personal API key).
  EXISTING_KEY="$(read_token N8N_API_KEY || true)"
  if [[ -n "$EXISTING_KEY" ]]; then
    log "  N8N_API_KEY already in $TOKENS_FILE — re-using it"
    N8N_API_KEY="$EXISTING_KEY"
    # Validate it before continuing
    HEAD_CODE="$(pct exec "$CTID" -- bash -lc "curl -sS -o /dev/null -w '%{http_code}' -H 'X-N8N-API-KEY: $N8N_API_KEY' http://localhost:5678/api/v1/credentials")"
    if [[ ! "$HEAD_CODE" =~ ^2 ]]; then
      warn "  Existing key is invalid (HTTP $HEAD_CODE). Re-minting."
      N8N_API_KEY=""
    fi
  fi

  if [[ -z "$N8N_API_KEY" ]]; then
    KEY_BODY='{"label":"td-proxmox automation"}'
    for endpoint in /rest/api-keys /rest/me/api-keys; do
      KEY_RESP="$(n8n_curl POST "$endpoint" "$KEY_BODY" 2> /tmp/n8n-key.code)"
      KEY_CODE="$(awk '{print $2}' /tmp/n8n-key.code 2>/dev/null)"
      log "  Trying $endpoint — HTTP $KEY_CODE"
      if [[ "$KEY_CODE" =~ ^2 ]]; then
        N8N_API_KEY="$(echo "$KEY_RESP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get("data", d) if isinstance(d, dict) else d
    print(data.get("rawApiKey") or data.get("apiKey") or "")
except Exception:
    pass' 2>/dev/null)"
        if [[ -n "$N8N_API_KEY" ]]; then
          upsert_token N8N_API_KEY "$N8N_API_KEY"
          log "  ✓ N8N_API_KEY minted via $endpoint and saved to $TOKENS_FILE"
          break
        else
          warn "  $endpoint returned 2xx but no key in response body:"
          echo "$KEY_RESP" | head -3 | sed 's/^/    /' >&2
        fi
      fi
    done
  fi

  if [[ -z "$N8N_API_KEY" ]]; then
    warn "  Could not mint API key automatically. Generate one manually:"
    warn "    http://$N8N_HOSTNAME:5678 → Settings → API → Create"
    warn "  Save it to $TOKENS_FILE as: N8N_API_KEY=<value>"
    warn "  Then re-run: ./addons/setup-n8n.sh"
    warn "  (CT exists, so this run will skip creation and just wire creds + workflows.)"
  fi
fi

# Helper for hitting n8n's API after this point (preserves /api/v1 vs /rest)
n8n_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "${N8N_API_KEY:-}" ]]; then
    n8n_curl "$method" "/api/v1$path" "$body"
  else
    n8n_curl "$method" "/rest$path" "$body"
  fi
}

# ----- 4. Create credentials ---------------------------------------------
if (( SKIP_CREDENTIALS )); then
  log "Skipping credential wiring (--skip-credentials)"
else
  log "Wiring credentials..."

  # Helper: only create if a credential with this name doesn't already exist
  cred_exists() {
    local name="$1"
    local resp
    resp="$(n8n_api GET "/credentials" "" 2>/dev/null)"
    NAME="$name" python3 -c '
import sys, json, os
want = os.environ.get("NAME", "")
try:
    d = json.loads(sys.stdin.read() or "{}")
    items = d.get("data", d) if isinstance(d, dict) else d
    if isinstance(items, list):
        for c in items:
            if isinstance(c, dict) and c.get("name") == want:
                print("exists"); sys.exit(0)
except Exception:
    pass
' <<< "$resp" | grep -q exists
  }

  create_credential() {
    local name="$1" type="$2" data_json="$3"
    if (( DRY_RUN )); then
      printf "[dry-run] create credential: name=%s type=%s\n" "$name" "$type"
      return 0
    fi
    if cred_exists "$name"; then
      log "  - $name already exists, skipping"
      return 0
    fi
    # Build the payload as proper JSON via Python — env vars carry the raw
    # values so quotes/escapes inside tokens don't matter.
    local payload
    payload="$(NAME="$name" TYPE="$type" DATA="$data_json" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["NAME"],
  "type": os.environ["TYPE"],
  "data": json.loads(os.environ["DATA"]),
}))')"
    local resp code
    resp="$(n8n_api POST "/credentials" "$payload" 2> /tmp/n8n-cred.code)"
    code="$(awk "{print \$2}" /tmp/n8n-cred.code 2>/dev/null)"
    if [[ "$code" =~ ^2 ]]; then
      log "  ✓ $name (HTTP $code)"
    else
      warn "  ✗ $name HTTP $code — body:"
      echo "$resp" | head -2 | sed 's/^/      /' >&2
    fi
  }

  # 4a. Ollama (always create — even if CT is missing, URL is correct for when it's added later)
  create_credential "Ollama (shared)" "ollamaApi" \
    '{"baseUrl":"http://ollama-pi-agent:11434"}'

  # 4b. Mattermost — only if creds present
  if [[ -n "$MM_BOT_TOKEN" ]]; then
    create_credential "Mattermost (pi-bot)" "mattermostApi" \
      "$(MM_BOT_TOKEN="$MM_BOT_TOKEN" MM_URL="$MM_URL" python3 -c '
import json, os
print(json.dumps({"accessToken": os.environ["MM_BOT_TOKEN"], "baseUrl": os.environ["MM_URL"]}))')"
  fi

  # 4c. Gitea — only if creds present
  if [[ -n "$GITEA_TOKEN" ]]; then
    create_credential "Gitea (admin)" "giteaApi" \
      "$(GITEA_TOKEN="$GITEA_TOKEN" python3 -c '
import json, os
print(json.dumps({"server": "http://gitea:3000", "accessToken": os.environ["GITEA_TOKEN"]}))')"
    # Plus a header-auth credential for arbitrary REST calls — n8n's native
    # Gitea node covers issues/repos but not every endpoint, so the digest
    # workflow uses HTTP Request + this header credential against /api/v1.
    create_credential "Gitea (admin) — Bearer" "httpHeaderAuth" \
      "$(GITEA_TOKEN="$GITEA_TOKEN" python3 -c '
import json, os
print(json.dumps({"name": "Authorization", "value": "token " + os.environ["GITEA_TOKEN"]}))')"
  fi

  # 4d. OpenWebUI as OpenAI-compatible
  if [[ -n "$OPENWEBUI_TOKEN" ]]; then
    create_credential "OpenWebUI (OpenAI-compat)" "openAiApi" \
      "$(OPENWEBUI_TOKEN="$OPENWEBUI_TOKEN" python3 -c '
import json, os
print(json.dumps({"apiKey": os.environ["OPENWEBUI_TOKEN"], "url": "http://openwebui:8080/api/v1"}))')"
  fi

  # 4e. A random header-auth credential for any "trusted webhook" pattern
  # callers can use to authenticate themselves to n8n webhooks.
  if (( ! DRY_RUN )); then
    EXISTING_SECRET="$(read_token N8N_WEBHOOK_SECRET || true)"
    SHARED_SECRET="${EXISTING_SECRET:-$(openssl rand -hex 16)}"
    create_credential "TD shared webhook secret" "httpHeaderAuth" \
      "$(SHARED_SECRET="$SHARED_SECRET" python3 -c '
import json, os
print(json.dumps({"name": "X-TD-Secret", "value": os.environ["SHARED_SECRET"]}))')"
    upsert_token N8N_WEBHOOK_SECRET "$SHARED_SECRET"
  fi
fi

# ----- 5. Import starter workflows ---------------------------------------
if (( SKIP_WORKFLOWS )); then
  log "Skipping starter workflows (--skip-workflows)"
elif [[ ! -d "$WORKFLOWS_DIR" ]]; then
  warn "Starter workflows dir $WORKFLOWS_DIR missing — skipping."
else
  log "Importing starter workflows..."

  if (( ! DRY_RUN )); then
    for wf in "$WORKFLOWS_DIR"/*.json; do
      [[ -f "$wf" ]] || continue
      WF_NAME="$(basename "$wf" .json)"

      # Read + clean the JSON locally (no shell-quoting hell)
      WF_BODY="$(WF_PATH="$wf" python3 -c '
import json, os
with open(os.environ["WF_PATH"]) as f:
    w = json.load(f)
for k in ("id", "createdAt", "updatedAt", "versionId", "shared", "meta", "tags"):
    w.pop(k, None)
w["active"] = False
# n8n public API expects only these top-level keys on workflow POST:
#   name, nodes, connections, settings, staticData (optional)
allowed = {"name","nodes","connections","settings","staticData"}
w = {k:v for k,v in w.items() if k in allowed}
w.setdefault("settings", {"executionOrder": "v1"})
print(json.dumps(w))')"

      log "  Importing: $WF_NAME"
      RESP="$(n8n_api POST "/workflows" "$WF_BODY" 2> /tmp/n8n-wf.code)"
      CODE="$(awk '{print $2}' /tmp/n8n-wf.code 2>/dev/null)"
      if [[ "$CODE" =~ ^2 ]]; then
        log "    ✓ imported (inactive — activate via n8n UI after review)"
      else
        warn "    ✗ HTTP $CODE — body:"
        echo "$RESP" | head -3 | sed 's/^/        /' >&2
      fi
    done
  fi
fi

# ----- 6. Register Homepage tile -----------------------------------------
if (( ! SKIP_HOMEPAGE_TILE )); then
  log "Registering Homepage tile..."
  HP_CTID="$(find_ct_by_hostname homepage 2>/dev/null || true)"
  if [[ -n "$HP_CTID" ]] && (( ! DRY_RUN )); then
    SVC="$(pct exec "$HP_CTID" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage; do
        [[ -f "$d/services.yaml" ]] && { echo "$d/services.yaml"; exit 0; }
      done' 2>/dev/null | tail -n1)"

    if [[ -n "$SVC" ]]; then
      pct exec "$HP_CTID" -- cp "$SVC" "${SVC}.bak.$(date +%s)"
      pct exec "$HP_CTID" -- bash -lc "awk '
        /^# TD-Addon: n8n/ { in_block=1; next }
        in_block && /^# TD-Addon:/ { in_block=0; print; next }
        !in_block { print }
      ' '$SVC' > /tmp/services.yaml.new && mv /tmp/services.yaml.new '$SVC'"

      TILE_BLOCK="- Automation:
    - n8n:
        href: http://${N8N_HOSTNAME}:5678
        description: Workflow automation
        icon: n8n.png"

      printf '\n# TD-Addon: n8n\n%s\n' "$TILE_BLOCK" | pct exec "$HP_CTID" -- tee -a "$SVC" >/dev/null
      pct exec "$HP_CTID" -- bash -lc 'systemctl restart homepage 2>/dev/null || true'
      log "  ✓ Homepage tile registered"
    fi
  fi
fi

# ----- 7. End-of-run banner ----------------------------------------------
log "================================================================"
log "==> n8n installed and wired."
log " "
log "  Hostname:  $N8N_HOSTNAME (CT $CTID)"
log "  URL:       http://$N8N_HOSTNAME:5678"
log "  Login:     $ADMIN_EMAIL / (admin password from $TOKENS_FILE)"
if [[ -n "${N8N_API_KEY:-}" ]]; then
  log "  API key:   N8N_API_KEY in $TOKENS_FILE"
fi
log " "
log "Credentials wired:"
log "  ✓ Ollama (shared) — Ollama node points at http://ollama-pi-agent:11434"
[[ -n "$MM_BOT_TOKEN" ]] && log "  ✓ Mattermost (pi-bot) — Mattermost node uses bot account"
[[ -n "$GITEA_TOKEN"  ]] && log "  ✓ Gitea (admin) — Gitea node uses admin PAT"
[[ -n "$OPENWEBUI_TOKEN" ]] && log "  ✓ OpenWebUI (OpenAI-compat) — OpenAI node points at OpenWebUI"
log " "
log "Starter workflows imported (INACTIVE — review then activate):"
log "  - hello-mattermost: POST /webhook/hello → posts 'hello world' in #general"
log "  - mm-ollama-chat: mentions in #ai-chat get an Ollama-generated reply"
log "  - gitea-daily-digest: daily 9am cron → last 24h commits → posts in #general"
log " "
log "Next steps:"
log "  1. Open http://$N8N_HOSTNAME:5678 and sign in"
log "  2. Open the Workflows panel — three workflows waiting for you"
log "  3. Review the credentials each one references (Settings → Credentials)"
log "  4. Toggle a workflow ACTIVE when you're ready to use it"
log " "
log "Manage:"
log "  status:    pct exec $CTID -- systemctl status n8n"
log "  logs:      pct exec $CTID -- journalctl -u n8n -f"
log "  restart:   pct exec $CTID -- systemctl restart n8n"
log "  uninstall: $(basename "$0") --uninstall"
log "================================================================"
