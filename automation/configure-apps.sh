#!/usr/bin/env bash
# configure-apps.sh — Wire up Gitea + OpenWebUI + pi after bootstrap-pve.sh.
# Runs on the PVE host. Uses `pct exec` into each CT, so no extra SSH plumbing.
#
# What it does:
#   1. Gitea (CT 202)
#      - Create admin user via `gitea admin user create` inside the CT.
#      - Mint an access token via `gitea admin user generate-access-token`.
#   2. OpenWebUI (CT 100)
#      - Create the first user (auto-admin) via /api/v1/auths/signup.
#      - Log in to grab a JWT.
#      - Add an OpenRouter connection via /api/v1/configs (OpenAI-compatible).
#   3. ollama-pi-agent (CT 200) — pi host
#      - Drop /root/.netrc with Gitea credentials (chmod 600).
#      - Export OPENROUTER_API_KEY in /root/.bashrc.
#   4. homepage (CT 110)
#      - Write a starter services.yaml, settings.yaml, bookmarks.yaml.
#      - Embed the Gitea widget (uses the token minted in step 1).
#      - Restart the homepage service.
#
# Outputs:
#   - All issued secrets written to /root/td-tokens.txt on the PVE host (chmod 600).
#   - Same secrets echoed at the end of the run.
#
# Usage (zero flags — script prompts for everything it needs):
#   ./configure-apps.sh
#
# Or pass any subset as flags:
#   ./configure-apps.sh \
#       --admin-user      td \
#       --admin-email     td@homelab.local \
#       --admin-password  'strong-pass' \
#       --openrouter-key  'sk-or-...'
#
# Required inputs (each can come from a flag OR an interactive prompt):
#   --admin-user      Admin username for Gitea + OpenWebUI (e.g. td).
#   --admin-email     Admin email (e.g. td@homelab.local).
#   --admin-password  Hidden input, confirmed twice, >= 8 chars.
#   --openrouter-key  Hidden input. Get from openrouter.ai → Keys → New Key.
#                     Must start with sk-or-.
#
# Optional CT-ID overrides (otherwise resolved by hostname):
#   --gitea-ctid 202        Override CT IDs if you used non-defaults
#   --openwebui-ctid 100
#   --pi-host-ctid 200      The ollama-pi-agent CT
#   --homepage-ctid 110     The Homepage dashboard CT
#   --only gitea,homepage   Subset of subsystems (gitea, openwebui, pi, homepage)
#   --dry-run               Preview commands; uses placeholders, skips prompts.

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
# CTIDs are looked up by HOSTNAME at startup (see resolve_ctids below). The
# community helper scripts auto-assign IDs that don't match our preferred
# numbers, so trusting static values silently misroutes work into the wrong CT.
# Hardcoded values here are only fallback "preferred" IDs and CLI override slots.
GITEA_CTID=""
OPENWEBUI_CTID=""
PI_HOST_CTID=""
HOMEPAGE_CTID=""

ADMIN_USER=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
OPENROUTER_KEY=""
ONLY=""
DRY_RUN=0

TOKENS_FILE="/root/td-tokens.txt"

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --openrouter-key) OPENROUTER_KEY="$2"; shift 2 ;;
    --gitea-ctid)     GITEA_CTID="$2"; shift 2 ;;
    --openwebui-ctid) OPENWEBUI_CTID="$2"; shift 2 ;;
    --pi-host-ctid)   PI_HOST_CTID="$2"; shift 2 ;;
    --homepage-ctid)  HOMEPAGE_CTID="$2"; shift 2 ;;
    --debian1-ctid)   PI_HOST_CTID="$2"; shift 2 ;;  # deprecated alias, accepted for back-compat
    --only)           ONLY="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[configure-apps]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[configure-apps]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[configure-apps]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — run this on the PVE host."

# ----- resolve admin / API inputs (flag OR prompt) --------------------------
# All four required inputs default to env / flag if passed, otherwise prompt
# interactively. Password + OpenRouter key prompts hide input. Same pattern
# as bootstrap-pve.sh — see resolve_sshkey / resolve_tsauthkey there.

resolve_admin_user() {
  if [[ -n "$ADMIN_USER" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_USER="dryrunuser"; log "Dry-run: using placeholder admin user."; return; fi
  printf "\n\033[1;36m[configure-apps]\033[0m Admin username for Gitea + OpenWebUI (e.g. td): " >&2
  IFS= read -r ADMIN_USER
  [[ -n "$ADMIN_USER" ]] || die "Admin user can't be empty."
}

resolve_admin_email() {
  if [[ -n "$ADMIN_EMAIL" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_EMAIL="dry@run.local"; log "Dry-run: using placeholder admin email."; return; fi
  printf "\n\033[1;36m[configure-apps]\033[0m Admin email (e.g. td@homelab.local): " >&2
  IFS= read -r ADMIN_EMAIL
  [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "That doesn't look like a valid email."
}

resolve_admin_password() {
  if [[ -n "$ADMIN_PASSWORD" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw"; log "Dry-run: using placeholder admin password."; return; fi
  local pw1 pw2
  printf "\n\033[1;36m[configure-apps]\033[0m Admin password (hidden; min 8 chars): " >&2
  IFS= read -rs pw1; echo >&2
  printf "Confirm: " >&2
  IFS= read -rs pw2; echo >&2
  [[ "$pw1" == "$pw2"  ]] || die "Passwords didn't match."
  [[ ${#pw1} -ge 8     ]] || die "Password too short (need >= 8 chars)."
  ADMIN_PASSWORD="$pw1"
}

resolve_openrouter_key() {
  if [[ -n "$OPENROUTER_KEY" ]]; then return; fi
  if (( DRY_RUN )); then OPENROUTER_KEY="sk-or-DRY_RUN_PLACEHOLDER"; log "Dry-run: using placeholder OpenRouter key."; return; fi
  printf "\n\033[1;36m[configure-apps]\033[0m OpenRouter API key (sk-or-... from openrouter.ai → Keys). Input hidden:\n> " >&2
  IFS= read -rs OPENROUTER_KEY
  echo >&2
  [[ "$OPENROUTER_KEY" =~ ^sk-or- ]] \
    || die "That doesn't look like an OpenRouter key (expected sk-or-...)."
}

resolve_admin_user
resolve_admin_email
resolve_admin_password
resolve_openrouter_key

selected() {
  local key="$1"
  if [[ -z "$ONLY" ]]; then return 0; fi
  IFS=',' read -ra wanted <<< "$ONLY"
  for w in "${wanted[@]}"; do [[ "$w" == "$key" ]] && return 0; done
  return 1
}

ct_up() {
  local CTID="$1"
  pct status "$CTID" 2>/dev/null | grep -q "status: running" \
    || die "CT $CTID is not running. Run bootstrap-pve.sh first."
}

# Find a CT by its hostname (since bootstrap-pve.sh sets these correctly even
# when the underlying CTID drifts from our preferred numbers).
find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Resolve each app to its actual CTID at startup. Honors CLI overrides; falls
# back to a hostname lookup; dies clearly if the CT isn't found.
resolve_ctids() {
  local missing=()

  if [[ -z "$GITEA_CTID" ]];     then GITEA_CTID="$(find_ct_by_hostname gitea     2>/dev/null || true)"; fi
  if [[ -z "$OPENWEBUI_CTID" ]]; then OPENWEBUI_CTID="$(find_ct_by_hostname openwebui 2>/dev/null || true)"; fi
  if [[ -z "$PI_HOST_CTID" ]];   then PI_HOST_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"; fi
  if [[ -z "$HOMEPAGE_CTID" ]];  then HOMEPAGE_CTID="$(find_ct_by_hostname homepage   2>/dev/null || true)"; fi

  # Only complain about the subsystems we're actually going to touch.
  selected gitea     && [[ -z "$GITEA_CTID"     ]] && missing+=("gitea")
  selected openwebui && [[ -z "$OPENWEBUI_CTID" ]] && missing+=("openwebui")
  selected pi        && [[ -z "$PI_HOST_CTID"   ]] && missing+=("ollama-pi-agent")
  selected homepage  && [[ -z "$HOMEPAGE_CTID"  ]] && missing+=("homepage")

  if (( ${#missing[@]} > 0 )); then
    die "Could not find CT(s) with hostname(s): ${missing[*]}.
  Run 'pct list' and confirm each CT exists and is named correctly.
  You can also pass explicit IDs via --gitea-ctid / --openwebui-ctid / --pi-host-ctid / --homepage-ctid."
  fi

  log "Resolved CTIDs: gitea=${GITEA_CTID:-skip}  openwebui=${OPENWEBUI_CTID:-skip}  pi-host=${PI_HOST_CTID:-skip}  homepage=${HOMEPAGE_CTID:-skip}"
}

# Wait for a TCP port inside a CT to be answering.
wait_for_port_inside_ct() {
  local CTID="$1" PORT="$2" WHAT="$3"
  local i=0
  while ! pct exec "$CTID" -- bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; do
    (( ++i > 30 )) && die "$WHAT (CT $CTID port $PORT) not responding after 60s."
    sleep 2
  done
}

# ----- Gitea -----------------------------------------------------------------

# Detect which system user gitea runs as. Community-scripts builds tend to use
# 'gitea'; older / source-builds sometimes use 'git'. Pick whichever exists.
_gitea_runas_user() {
  local ctid="$1" u
  for u in gitea git gitea-web; do
    pct exec "$ctid" -- id "$u" >/dev/null 2>&1 && { echo "$u"; return; }
  done
  echo gitea  # safe fallback
}

# Detect the on-disk app.ini path (community helper may use either of these).
_gitea_config_path() {
  local ctid="$1" p
  for p in /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini /opt/gitea/custom/conf/app.ini; do
    pct exec "$ctid" -- test -f "$p" 2>/dev/null && { echo "$p"; return; }
  done
  echo /etc/gitea/app.ini  # the path the install POST will write to
}

# Is the first-run install wizard still up? Two signals:
#   1. No app.ini on disk yet, OR
#   2. /install endpoint reachable + returns the install page (200 with form)
# Either means we need to POST /install before any CLI work.
gitea_install_lock_on() {
  local ctid="$1"
  pct exec "$ctid" -- bash -lc '
    for p in /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini /opt/gitea/custom/conf/app.ini; do
      [[ -f "$p" ]] && grep -qE "^INSTALL_LOCK\s*=\s*true" "$p" && exit 0
    done
    exit 1
  ' >/dev/null 2>&1
}

# Run the first-run install by POSTing the form. Sets up SQLite3 and the
# defaults the community helper omitted. After this, app.ini is on disk and
# INSTALL_LOCK = true, so subsequent CLI commands work.
gitea_first_run_setup() {
  local ctid="$1"
  local ip="$2"

  if (( ! DRY_RUN )) && gitea_install_lock_on "$ctid"; then
    log "  Gitea install lock already set — first-run setup skipped."
    return
  fi

  if (( DRY_RUN )); then
    log "  [dry-run] Would POST /install (SQLite3, default paths) and wait for app.ini."
    log "  [dry-run] Skipping the real verification loop so dry-run can finish."
  else
    log "  First-run wizard detected. POSTing /install (SQLite3, default paths)..."
  fi

  # The form expects URL-encoded fields. We feed them through curl --data-urlencode
  # so the server sees the same shape as the browser would. The fields below
  # match what's visible in the install page screenshot — anything we leave out
  # uses the server's default.
  run "pct exec $ctid -- curl -fsS -X POST 'http://127.0.0.1:3000/' \
       --data-urlencode 'db_type=sqlite3' \
       --data-urlencode 'db_host=' \
       --data-urlencode 'db_user=' \
       --data-urlencode 'db_passwd=' \
       --data-urlencode 'db_name=gitea' \
       --data-urlencode 'ssl_mode=disable' \
       --data-urlencode 'db_schema=' \
       --data-urlencode 'charset=utf8' \
       --data-urlencode 'db_path=/var/lib/gitea/data/gitea.db' \
       --data-urlencode 'app_name=Gitea' \
       --data-urlencode 'repo_root_path=/var/lib/gitea/data/gitea-repositories' \
       --data-urlencode 'lfs_root_path=/var/lib/gitea/data/lfs' \
       --data-urlencode 'run_user=gitea' \
       --data-urlencode 'domain=${ip}' \
       --data-urlencode 'ssh_port=22' \
       --data-urlencode 'http_port=3000' \
       --data-urlencode 'app_url=http://${ip}:3000/' \
       --data-urlencode 'log_root_path=/var/lib/gitea/log' \
       --data-urlencode 'smtp_addr=' --data-urlencode 'smtp_port=' \
       --data-urlencode 'smtp_from=' --data-urlencode 'smtp_user=' \
       --data-urlencode 'smtp_passwd=' \
       --data-urlencode 'offline_mode=on' \
       --data-urlencode 'default_allow_create_organization=on' \
       --data-urlencode 'default_enable_timetracking=on' \
       --data-urlencode 'no_reply_address=noreply.localhost' \
       --data-urlencode 'password_algorithm=pbkdf2' \
       -o /dev/null"

  # Dry-run never actually POSTs, so don't wait for state that won't change.
  if (( DRY_RUN )); then return; fi

  # Wait for app.ini to appear (Gitea writes it during the install POST, then
  # restarts itself; can take a few seconds).
  local i=0
  while ! gitea_install_lock_on "$ctid"; do
    (( ++i > 20 )) && die "  Gitea didn't finalize install after 40s. Check pct exec $ctid -- journalctl -u gitea --no-pager | tail -20"
    sleep 2
  done
  log "  Install complete. app.ini written, INSTALL_LOCK = true."

  # Wait again for the daemon to come back on port 3000 after the post-install restart.
  wait_for_port_inside_ct "$ctid" 3000 "Gitea (post-install restart)"
}

configure_gitea() {
  ct_up "$GITEA_CTID"
  log "Configuring Gitea (CT $GITEA_CTID)..."

  wait_for_port_inside_ct "$GITEA_CTID" 3000 "Gitea"

  # Pick up the CT's IP early so the first-run setup can use it.
  GITEA_IP="$(pct exec "$GITEA_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "10.0.0.0")"

  # Finalize the install wizard if it's still up (community helper sometimes
  # ships Gitea with the binary running but no app.ini, leaving the SQLite3
  # / MySQL / Postgres picker on screen). Always safe to call — exits early
  # if install is already locked.
  gitea_first_run_setup "$GITEA_CTID" "$GITEA_IP"

  local GITEA_USER GITEA_CONFIG
  GITEA_USER="$(_gitea_runas_user "$GITEA_CTID")"
  GITEA_CONFIG="$(_gitea_config_path "$GITEA_CTID")"
  log "  Detected Gitea run-as user: $GITEA_USER (config: $GITEA_CONFIG)"

  # Create admin user (idempotent — Gitea errors if user exists; we ignore that case)
  log "  Creating admin user: $ADMIN_USER"
  run "pct exec $GITEA_CTID -- bash -lc \"sudo -u $GITEA_USER gitea admin user create \
        --username '$ADMIN_USER' \
        --password '$ADMIN_PASSWORD' \
        --email    '$ADMIN_EMAIL' \
        --admin \
        --must-change-password=false \
        --config $GITEA_CONFIG || echo '  (user may already exist)'\""

  # Mint an access token with full scope
  log "  Minting access token (name: pi-agent)..."
  GITEA_TOKEN=""
  if (( ! DRY_RUN )); then
    # Gitea's success message is one of:
    #   "Access token was successfully created: <hex>"   (newer versions)
    #   "Access token: <hex>"                            (older versions)
    # Both have the token as the last field, so use $NF rather than splitting
    # on ': ' (which broke for the newer format — $2 = "was successfully created").
    GITEA_TOKEN="$(pct exec "$GITEA_CTID" -- bash -lc "sudo -u $GITEA_USER gitea admin user generate-access-token \
        --username '$ADMIN_USER' \
        --token-name 'pi-agent' \
        --scopes 'all' \
        --config $GITEA_CONFIG 2>/dev/null | awk '/^Access token/{print \$NF}'" || true)"
    if [[ -z "$GITEA_TOKEN" ]]; then
      warn "  Token generation returned empty — token may already exist with this name. Re-run with a fresh --token-name or revoke in Gitea UI."
    fi
  else
    GITEA_TOKEN="DRYRUN_GITEA_TOKEN_PLACEHOLDER"
  fi

  log "  Gitea reachable at: http://$GITEA_IP:3000"
}

# ----- OpenWebUI -------------------------------------------------------------
# Helper: POST a JSON body to an OpenWebUI endpoint and capture both the body
# and HTTP status, so we can distinguish "user already exists" from "endpoint
# missing" from "service still starting" etc.
_owui_post_json() {
  local ctid="$1" path="$2" body="$3"
  pct exec "$ctid" -- bash -lc "curl -sS -w '\nHTTP_STATUS:%{http_code}' \
    -X POST 'http://127.0.0.1:8080$path' \
    -H 'Content-Type: application/json' \
    -d '$body'" 2>/dev/null || echo "HTTP_STATUS:000"
}

# Extract HTTP_STATUS and body from a combined response.
_owui_parse_status() { echo "$1" | grep -oE 'HTTP_STATUS:[0-9]+' | tail -1 | cut -d: -f2; }
_owui_parse_body()   { echo "$1" | sed '/^HTTP_STATUS:/d'; }

configure_openwebui() {
  ct_up "$OPENWEBUI_CTID"
  log "Configuring OpenWebUI (CT $OPENWEBUI_CTID)..."

  wait_for_port_inside_ct "$OPENWEBUI_CTID" 8080 "OpenWebUI"

  local OWUI_TOKEN=""

  if (( DRY_RUN )); then
    OWUI_TOKEN="DRYRUN_OWUI_JWT"
  else
    # OpenWebUI's signup response includes the JWT directly — no need for a
    # separate signin call on the happy path. We try signup first; if it
    # returns 4xx (user already exists, etc.) we fall back to signin.
    log "  Creating admin user via signup..."
    local SIGNUP_BODY SIGNUP_RESP SIGNUP_STATUS SIGNUP_BODY_RESP
    SIGNUP_BODY=$(printf '{"name":"%s","email":"%s","password":"%s","profile_image_url":"/user.png"}' \
      "$ADMIN_USER" "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
    SIGNUP_RESP=$(_owui_post_json "$OPENWEBUI_CTID" "/api/v1/auths/signup" "$SIGNUP_BODY")
    SIGNUP_STATUS=$(_owui_parse_status "$SIGNUP_RESP")
    SIGNUP_BODY_RESP=$(_owui_parse_body "$SIGNUP_RESP")

    if [[ "$SIGNUP_STATUS" == "200" || "$SIGNUP_STATUS" == "201" ]]; then
      OWUI_TOKEN=$(echo "$SIGNUP_BODY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
      log "  Admin user created. JWT obtained from signup response."
    else
      log "  Signup returned $SIGNUP_STATUS — likely user already exists. Trying signin..."
      local SIGNIN_BODY SIGNIN_RESP SIGNIN_STATUS SIGNIN_BODY_RESP
      SIGNIN_BODY=$(printf '{"email":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
      SIGNIN_RESP=$(_owui_post_json "$OPENWEBUI_CTID" "/api/v1/auths/signin" "$SIGNIN_BODY")
      SIGNIN_STATUS=$(_owui_parse_status "$SIGNIN_RESP")
      SIGNIN_BODY_RESP=$(_owui_parse_body "$SIGNIN_RESP")
      if [[ "$SIGNIN_STATUS" == "200" ]]; then
        OWUI_TOKEN=$(echo "$SIGNIN_BODY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
        log "  Signed in. JWT obtained."
      else
        warn "  Both signup ($SIGNUP_STATUS) and signin ($SIGNIN_STATUS) failed."
        warn "  Signup body: $SIGNUP_BODY_RESP"
        warn "  Signin body: $SIGNIN_BODY_RESP"
      fi
    fi

    if [[ -z "$OWUI_TOKEN" ]]; then
      warn "  Could not retrieve OpenWebUI JWT — skipping OpenRouter connection."
      warn "  Recover by signing into http://<openwebui-ip>:8080 in a browser, then"
      warn "  Settings → Connections → + on the OpenAI API row → URL https://openrouter.ai/api/v1"
    fi
  fi

  # Add OpenRouter as an OpenAI-compatible connection via /openai/config/update.
  # Schema (OpenAIConfigForm) requires: OPENAI_API_BASE_URLS, OPENAI_API_KEYS,
  # OPENAI_API_CONFIGS. The fourth field ENABLE_OPENAI_API is optional but we
  # set it explicitly so the new connection actually shows up in the chat.
  #
  # OPENAI_API_CONFIGS is a dict keyed by the URL index (0, 1, ...) where each
  # value is a per-connection settings object. An empty {} satisfies the
  # required-field constraint and OpenWebUI fills defaults. If you want
  # per-connection tags/prefix/model filtering you'd populate it here.
  if [[ -n "$OWUI_TOKEN" ]]; then
    log "  Adding OpenRouter connection (POST /openai/config/update)..."
    local CONN_BODY
    CONN_BODY=$(printf '{"OPENAI_API_BASE_URLS":["https://openrouter.ai/api/v1"],"OPENAI_API_KEYS":["%s"],"OPENAI_API_CONFIGS":{},"ENABLE_OPENAI_API":true}' \
      "$OPENROUTER_KEY")
    if (( ! DRY_RUN )); then
      local CONN_RESP CONN_STATUS CONN_BODY_RESP
      CONN_RESP=$(pct exec "$OPENWEBUI_CTID" -- bash -lc "curl -sS -w '\nHTTP_STATUS:%{http_code}' \
        -X POST 'http://127.0.0.1:8080/openai/config/update' \
        -H 'Authorization: Bearer $OWUI_TOKEN' \
        -H 'Content-Type: application/json' \
        -d '$CONN_BODY'" 2>/dev/null || echo "HTTP_STATUS:000")
      CONN_STATUS=$(_owui_parse_status "$CONN_RESP")
      CONN_BODY_RESP=$(_owui_parse_body "$CONN_RESP")
      if [[ "$CONN_STATUS" =~ ^2 ]]; then
        log "  OpenRouter connection added (HTTP $CONN_STATUS)."
      else
        warn "  /openai/config/update returned $CONN_STATUS."
        warn "  Body: $CONN_BODY_RESP"
        warn "  Add OpenRouter manually: Settings → Connections → + on OpenAI API row."
      fi
    else
      printf "[dry-run] would POST OpenRouter connection to /openai/config/update.\n"
    fi
  fi

  OWUI_IP="$(pct exec "$OPENWEBUI_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "10.0.0.0")"
  log "  OpenWebUI reachable at: http://$OWUI_IP:8080"
}

# ----- ollama-pi-agent (pi host) --------------------------------------------
configure_pi_host() {
  ct_up "$PI_HOST_CTID"
  log "Seeding pi config on ollama-pi-agent (CT $PI_HOST_CTID)..."

  # 1. .netrc for Gitea (so `git push` and curl-with-machine work without prompting)
  #
  # libcurl matches .netrc machine entries by the EXACT hostname from the URL.
  # Inside the tailnet, scripts use 'http://gitea:3000/...' (MagicDNS); on the
  # LAN they might use 'http://<gitea-ct-ip>:3000/...'. Both URL forms are
  # common, so we write a machine entry for each. Without this, the IP-keyed
  # entry won't match a 'gitea' URL and git push falls through to prompting
  # for username + password every time.
  log "  Writing /root/.netrc with Gitea credentials (both 'gitea' and IP)..."
  local GITEA_IP_LINE=""
  if [[ -n "${GITEA_IP:-}" ]]; then
    GITEA_IP_LINE="
machine $GITEA_IP
  login   $ADMIN_USER
  password ${GITEA_TOKEN:-CHANGEME}"
  fi
  run "pct exec $PI_HOST_CTID -- bash -c 'cat > /root/.netrc <<NETRC
machine gitea
  login   $ADMIN_USER
  password ${GITEA_TOKEN:-CHANGEME}$GITEA_IP_LINE
NETRC
chmod 600 /root/.netrc'"

  # 2. Persist OPENROUTER_API_KEY for pi
  log "  Exporting OPENROUTER_API_KEY in /root/.bashrc..."
  run "pct exec $PI_HOST_CTID -- bash -c '
    grep -q OPENROUTER_API_KEY /root/.bashrc || \
      echo \"export OPENROUTER_API_KEY=$OPENROUTER_KEY\" >> /root/.bashrc
  '"

  log "  (Add OpenRouter to pi as a model provider on first launch — pi's own provider config isn't scripted here yet.)"
}

# ----- homepage dashboard ----------------------------------------------------
configure_homepage() {
  ct_up "$HOMEPAGE_CTID"
  log "Configuring Homepage (CT $HOMEPAGE_CTID)..."

  # Find Homepage's config directory. The community-scripts install lands at
  # /opt/homepage/config in most builds, but we probe a few fallbacks so this
  # keeps working if the upstream layout shifts.
  local CONFIG_DIR=""
  if (( ! DRY_RUN )); then
    CONFIG_DIR="$(pct exec "$HOMEPAGE_CTID" -- bash -lc '
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
        if [[ -d "$d" ]] && ls "$d"/*.yaml >/dev/null 2>&1 || [[ -d "$d" ]]; then
          echo "$d"; exit 0
        fi
      done
      echo /opt/homepage/config
    ' 2>/dev/null | tail -n1)"
  else
    CONFIG_DIR="/opt/homepage/config"
  fi
  log "  Using config dir: $CONFIG_DIR"
  run "pct exec $HOMEPAGE_CTID -- mkdir -p '$CONFIG_DIR'"

  # PVE host IP for the bookmark — grab from outside the CT so we get the
  # management address, not the CT's own.
  local PVE_IP="${PVE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  : "${PVE_IP:=10.0.0.1}"

  # Gitea token may be empty if --only homepage was used without --only gitea.
  local GITEA_KEY="${GITEA_TOKEN:-REPLACE_WITH_GITEA_TOKEN}"

  # ---- services.yaml ----
  log "  Writing $CONFIG_DIR/services.yaml ..."
  run "pct exec $HOMEPAGE_CTID -- bash -c 'cat > $CONFIG_DIR/services.yaml <<\"YAML\"
---
- Development:
    - Gitea:
        href: http://gitea:3000
        description: Self-hosted git, code, and tokens
        icon: gitea.png
        widget:
          type: gitea
          url: http://gitea:3000
          key: $GITEA_KEY

- AI:
    - Open WebUI:
        href: http://openwebui:8080
        description: Chat with OpenRouter + Ollama models
        icon: open-webui.png

    - Ollama Pi Agent:
        description: pi coding agent runtime (ssh root@ollama-pi-agent)
        icon: ollama.png

- Sandbox:
    - Docker:
        description: Docker host for ad-hoc deployments (ssh root@docker)
        icon: docker.png
YAML'"

  # ---- settings.yaml ----
  log "  Writing $CONFIG_DIR/settings.yaml ..."
  run "pct exec $HOMEPAGE_CTID -- bash -c 'cat > $CONFIG_DIR/settings.yaml <<\"YAML\"
---
title: TD Homelab
theme: dark
color: slate
headerStyle: clean
layout:
  Development:
    style: row
    columns: 1
  AI:
    style: row
    columns: 2
  Sandbox:
    style: row
    columns: 1
YAML'"

  # ---- bookmarks.yaml ----
  log "  Writing $CONFIG_DIR/bookmarks.yaml ..."
  run "pct exec $HOMEPAGE_CTID -- bash -c 'cat > $CONFIG_DIR/bookmarks.yaml <<\"YAML\"
---
- Admin Consoles:
    - Proxmox:
        - abbr: PVE
          href: https://$PVE_IP:8006
    - Tailscale:
        - abbr: TS
          href: https://login.tailscale.com/admin/machines
- AI Providers:
    - OpenRouter:
        - abbr: OR
          href: https://openrouter.ai
    - Ollama:
        - abbr: OL
          href: https://ollama.com
YAML'"

  # ---- widgets.yaml ---- (top-of-page weather / search / resources)
  log "  Writing $CONFIG_DIR/widgets.yaml ..."
  run "pct exec $HOMEPAGE_CTID -- bash -c 'cat > $CONFIG_DIR/widgets.yaml <<\"YAML\"
---
- resources:
    cpu: true
    memory: true
    disk: /
- search:
    provider: duckduckgo
    target: _blank
YAML'"

  # Drop a systemd override setting HOMEPAGE_ALLOWED_HOSTS=*. Homepage v0.10+
  # validates the incoming Host header against an allowlist; community-scripts
  # installs don't set one, so the default deployment rejects any access
  # except 'localhost'. '*' accepts any Host — fine for a private homelab.
  # Idempotent — re-runs no-op if the drop-in is already present.
  log "  Allowing all Host headers (HOMEPAGE_ALLOWED_HOSTS=*)..."
  run "pct exec $HOMEPAGE_CTID -- bash -lc '
    mkdir -p /etc/systemd/system/homepage.service.d
    cat > /etc/systemd/system/homepage.service.d/allowed-hosts.conf <<DROPIN
[Service]
Environment=\"HOMEPAGE_ALLOWED_HOSTS=*\"
DROPIN
    systemctl daemon-reload
  '"

  # Restart the service so the new config + drop-in take effect. The unit name
  # varies by install method, so we try the most common ones.
  log "  Restarting Homepage service..."
  run "pct exec $HOMEPAGE_CTID -- bash -lc '
    systemctl restart homepage 2>/dev/null \
      || systemctl restart gethomepage 2>/dev/null \
      || systemctl restart homepage.service 2>/dev/null \
      || echo \"  (no homepage systemd unit found — restart manually)\"
  '"

  HOMEPAGE_IP="$(pct exec "$HOMEPAGE_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<homepage-ip>")"
  log "  Homepage reachable at: http://$HOMEPAGE_IP:3000  (or http://homepage:3000 on the tailnet)"
}

# ----- final summary ---------------------------------------------------------
write_summary() {
  local now; now="$(date -Iseconds)"
  local body
  body="$(cat <<EOF
# TD-Proxmox app credentials  ($now)
# Treat this file as secret. chmod 600.

ADMIN_USER=$ADMIN_USER
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASSWORD=$ADMIN_PASSWORD

GITEA_URL=http://${GITEA_IP:-<gitea-ip>}:3000
GITEA_TOKEN=${GITEA_TOKEN:-<not-generated>}

OPENWEBUI_URL=http://${OWUI_IP:-<openwebui-ip>}:8080
HOMEPAGE_URL=http://${HOMEPAGE_IP:-<homepage-ip>}:3000

OPENROUTER_API_KEY=$OPENROUTER_KEY
EOF
)"

  run "umask 077 && cat > '$TOKENS_FILE' <<'TOKENS'
$body
TOKENS"

  log "==> Summary written to $TOKENS_FILE"
  echo "----------------------------------------"
  echo "$body"
  echo "----------------------------------------"
}

# ----- driver ----------------------------------------------------------------
main() {
  log "==> Configure apps: Gitea + OpenWebUI + pi (ollama-pi-agent) + Homepage"
  resolve_ctids
  selected gitea     && configure_gitea
  selected openwebui && configure_openwebui
  selected pi        && configure_pi_host
  selected homepage  && configure_homepage
  write_summary
  log "==> Done."
}

main "$@"
