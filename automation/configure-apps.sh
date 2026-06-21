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
#   --only gitea,homepage   Subset of subsystems (gitea, openwebui, pi, homepage, filebrowser)
#   --skip-filebrowser      Don't install filebrowser on ollama-pi-agent / sandbox
#   --dry-run               Preview commands; uses placeholders, skips prompts.

set -Eeuo pipefail

# Resolve our own location so configure_filebrowser can find the sibling
# addon script (addons/setup-filebrowser.sh) regardless of how this script
# was invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- defaults --------------------------------------------------------------
# CTIDs are looked up by HOSTNAME at startup (see resolve_ctids below). The
# community helper scripts auto-assign IDs that don't match our preferred
# numbers, so trusting static values silently misroutes work into the wrong CT.
# Hardcoded values here are only fallback "preferred" IDs and CLI override slots.
GITEA_CTID=""
OPENWEBUI_CTID=""
PI_HOST_CTID=""
HOMEPAGE_CTID=""
SANDBOX_CTID=""  # Used only by configure_homepage and configure_filebrowser
                 # to decide whether to render/install for sandbox.

ADMIN_USER=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
OPENROUTER_KEY=""
ONLY=""
SKIP_FILEBROWSER=0
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
    --skip-filebrowser) SKIP_FILEBROWSER=1; shift ;;
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
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    # When --admin-password was passed via flag, still validate length so
    # downstream filebrowser doesn't barf later. 12 chars is filebrowser's
    # hardcoded minimum since recent versions.
    [[ ${#ADMIN_PASSWORD} -ge 12 ]] \
      || die "Admin password from --admin-password is too short (need >= 12 chars to satisfy filebrowser)."
    return
  fi
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw-12"; log "Dry-run: using placeholder admin password."; return; fi
  local pw1 pw2
  # 12 char minimum is dictated by filebrowser (the most strict of the
  # services we configure). Gitea/OpenWebUI accept anything 8+, but enforcing
  # one number everywhere means a single password works across all four.
  printf "\n\033[1;36m[configure-apps]\033[0m Admin password (hidden; min 12 chars — filebrowser's requirement): " >&2
  IFS= read -rs pw1; echo >&2
  printf "Confirm: " >&2
  IFS= read -rs pw2; echo >&2
  [[ "$pw1" == "$pw2"  ]] || die "Passwords didn't match."
  [[ ${#pw1} -ge 12    ]] || die "Password too short (need >= 12 chars to satisfy filebrowser)."
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
  # sandbox is optional (omitted by bootstrap's --skip-sandbox) — used only
  # by configure_homepage to decide whether to render the Sandbox tile.
  # Look for both 'sandbox' and 'docker' to cover the pre-rename state.
  if [[ -z "$SANDBOX_CTID" ]]; then
    SANDBOX_CTID="$(find_ct_by_hostname sandbox 2>/dev/null || true)"
    [[ -z "$SANDBOX_CTID" ]] && SANDBOX_CTID="$(find_ct_by_hostname docker 2>/dev/null || true)"
  fi

  # Only complain about the subsystems we're actually going to touch. Core
  # CTs (gitea, ollama-pi-agent, homepage) are hard requirements — if any is
  # missing, the homelab can't be configured. openwebui is optional: it can
  # be skipped at bootstrap (--skip-openwebui), so a missing openwebui CT
  # means we silently skip the openwebui configure step rather than failing.
  selected gitea     && [[ -z "$GITEA_CTID"     ]] && missing+=("gitea")
  selected pi        && [[ -z "$PI_HOST_CTID"   ]] && missing+=("ollama-pi-agent")
  selected homepage  && [[ -z "$HOMEPAGE_CTID"  ]] && missing+=("homepage")

  if (( ${#missing[@]} > 0 )); then
    die "Could not find CT(s) with hostname(s): ${missing[*]}.
  Run 'pct list' and confirm each CT exists and is named correctly.
  You can also pass explicit IDs via --gitea-ctid / --openwebui-ctid / --pi-host-ctid / --homepage-ctid."
  fi

  # If openwebui was explicitly requested via --only and isn't present, that's
  # a hard error (the user asked for something that doesn't exist).
  if [[ -n "$ONLY" ]] && selected openwebui && [[ -z "$OPENWEBUI_CTID" ]]; then
    die "openwebui requested via --only but no CT with that hostname exists.
  Either install openwebui (re-run bootstrap-pve.sh without --skip-openwebui) or drop it from --only."
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

  # Mint an access token with full scope.
  #
  # We use Gitea's REST API rather than the `gitea admin user ...` CLI here
  # because the CLI's token-management surface keeps changing across versions
  # (Gitea 1.26 removed --username from delete-access-token and
  # list-access-tokens, breaking the prior implementation). The API has
  # been stable since 1.18:
  #
  #   DELETE /api/v1/users/{user}/tokens/{name}   → idempotent delete
  #   POST   /api/v1/users/{user}/tokens          → mint, returns sha1
  #
  # Both endpoints accept basic auth as the target user. We have
  # $ADMIN_PASSWORD already.
  log "  Minting access token (name: pi-agent) via REST API..."
  GITEA_TOKEN=""
  if (( ! DRY_RUN )); then
    local api="http://${GITEA_IP}:3000/api/v1/users/${ADMIN_USER}/tokens"

    # Step 1: delete any existing token with our name. 204 = deleted,
    # 404 = wasn't there. Either is fine; we just need it gone.
    local del_status
    del_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
      -X DELETE "${api}/pi-agent")
    case "$del_status" in
      204) log "    Deleted existing pi-agent token." ;;
      404) log "    No prior pi-agent token to delete." ;;
      *)   warn "    Unexpected HTTP $del_status when deleting old token (continuing anyway)." ;;
    esac

    # Step 2: mint fresh. POST returns the sha1 in the JSON body. We don't
    # require jq — a small grep extracts the field.
    local mint_resp
    mint_resp=$(curl -s \
      -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
      -X POST "${api}" \
      -H "Content-Type: application/json" \
      -d '{"name":"pi-agent","scopes":["all"]}')

    GITEA_TOKEN=$(printf '%s' "$mint_resp" | grep -oE '"sha1":"[^"]+"' | head -1 | cut -d'"' -f4)

    # Step 3: validate the token actually works against the API. Catches
    # the case where mint returned 201 with a malformed token, or where
    # something else is off in the auth chain.
    if [[ -n "$GITEA_TOKEN" ]]; then
      local val_status
      val_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $GITEA_TOKEN" \
        "http://${GITEA_IP}:3000/api/v1/user")
      if [[ "$val_status" != "200" ]]; then
        warn "    Token minted but API validation returned HTTP $val_status — token may be unusable."
        GITEA_TOKEN=""
      else
        log "    Token validated (200 from /api/v1/user)."
      fi
    fi

    if [[ -z "$GITEA_TOKEN" ]]; then
      warn "  Token mint via API returned empty / invalid token."
      warn "  Raw response from Gitea was:"
      printf '    %s\n' "$mint_resp" >&2
      warn "  Homepage Gitea widget will fall back to placeholder key — fix manually:"
      warn "    1) Generate a token in Gitea UI → http://$GITEA_IP:3000/-/user/settings/applications"
      warn "    2) sed -i 's|key: REPLACE_WITH_GITEA_TOKEN|key: <your-token>|' <homepage-services.yaml>"
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
  # When that happens, try to recover the previously-written token from the
  # existing services.yaml so the widget keeps working across re-runs. If
  # nothing's there either, fall back to the placeholder and warn loudly.
  local GITEA_KEY="${GITEA_TOKEN}"
  if [[ -z "$GITEA_KEY" ]]; then
    local EXISTING_KEY
    EXISTING_KEY="$(pct exec "$HOMEPAGE_CTID" -- bash -lc "
      for d in /opt/homepage/config /opt/homepage /homepage/config /etc/homepage /var/lib/homepage/config; do
        if [[ -f \"\$d/services.yaml\" ]]; then
          awk '/type: gitea/,/^- / { if (\$1==\"key:\") {print \$2; exit} }' \"\$d/services.yaml\"
          exit
        fi
      done
    " 2>/dev/null | tr -d '\r\n ')"
    if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "REPLACE_WITH_GITEA_TOKEN" ]]; then
      log "  Reusing existing Gitea token from prior services.yaml (configure_gitea not run this invocation)."
      GITEA_KEY="$EXISTING_KEY"
    else
      warn "  GITEA_TOKEN is empty AND no usable token in existing services.yaml."
      warn "  Homepage Gitea widget will render with placeholder key (won't fetch data)."
      warn "  Fix: re-run with 'configure-apps.sh --only gitea,homepage' to mint + wire fresh."
      GITEA_KEY="REPLACE_WITH_GITEA_TOKEN"
    fi
  fi

  # ---- services.yaml ----
  # Build conditionally so the Open WebUI tile and the Sandbox group are
  # omitted when their CTs weren't installed (bootstrap's --skip-openwebui
  # / --skip-sandbox). Otherwise Homepage shows tiles that link to nothing,
  # which is confusing.
  log "  Writing $CONFIG_DIR/services.yaml ..."

  local SERVICES_YAML="---
- Development:
    - Gitea:
        href: http://gitea:3000
        description: Self-hosted git, code, and tokens
        icon: gitea.png
        widget:
          type: gitea
          url: http://gitea:3000
          key: $GITEA_KEY

- AI:"
  if [[ -n "$OPENWEBUI_CTID" ]]; then
    SERVICES_YAML+="
    - Open WebUI:
        href: http://openwebui:8080
        description: Chat with OpenRouter + Ollama models
        icon: open-webui.png
"
  fi
  SERVICES_YAML+="
    - Ollama Pi Agent:
        description: pi coding agent runtime (ssh root@ollama-pi-agent)
        icon: ollama.png"

  # Resolve the sandbox hostname once (could be 'sandbox' or 'docker' for
  # users mid-rename). Both the Sandbox group tile AND the filebrowser tile
  # below need it.
  local SANDBOX_HOSTNAME=""
  if [[ -n "$SANDBOX_CTID" ]]; then
    SANDBOX_HOSTNAME="$(pct config "$SANDBOX_CTID" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    : "${SANDBOX_HOSTNAME:=sandbox}"
  fi

  if [[ -n "$SANDBOX_CTID" ]]; then
    SERVICES_YAML+="

- Sandbox:
    - Docker:
        description: Docker host for ad-hoc deployments (ssh root@$SANDBOX_HOSTNAME)
        icon: docker.png"
  fi

  # ---- Tools group: filebrowser instances --------------------------------
  # We embed filebrowser tiles inline in the authoritative services.yaml
  # rather than depending on setup-filebrowser.sh's marker-based addon
  # registration. configure_filebrowser passes --skip-homepage-tile so the
  # addon doesn't double-register. Net effect: a single Tools section in
  # services.yaml, owned by this script.
  if (( ! SKIP_FILEBROWSER )); then
    local TOOLS_TILES=""
    if [[ -n "$PI_HOST_CTID" ]]; then
      TOOLS_TILES+="
    - Files on ollama-pi-agent:
        href: http://ollama-pi-agent:8080
        description: Drop files for pi to use (/root/uploads/)
        icon: filebrowser.png"
    fi
    if [[ -n "$SANDBOX_CTID" ]]; then
      TOOLS_TILES+="
    - Files on $SANDBOX_HOSTNAME:
        href: http://$SANDBOX_HOSTNAME:8080
        description: Drop files for Docker workloads (/root/uploads/)
        icon: filebrowser.png"
    fi
    if [[ -n "$TOOLS_TILES" ]]; then
      SERVICES_YAML+="

- Tools:$TOOLS_TILES"
    fi
  fi

  # Write via heredoc; the printf %s ... is fed into pct exec's stdin which
  # then redirects to the file. Cleaner than embedding the multi-line string
  # in a 'bash -c cat <<YAML' which has quoting hell.
  if (( DRY_RUN )); then
    printf '[dry-run] would write services.yaml:\n%s\n' "$SERVICES_YAML"
  else
    printf '%s\n' "$SERVICES_YAML" | pct exec "$HOMEPAGE_CTID" -- tee "$CONFIG_DIR/services.yaml" > /dev/null
  fi

  # ---- settings.yaml ----
  # Same conditional treatment — only include layout entries for groups that
  # actually have tiles, otherwise Homepage gives weird empty group renders.
  log "  Writing $CONFIG_DIR/settings.yaml ..."

  local SETTINGS_YAML="---
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
    columns: $([[ -n "$OPENWEBUI_CTID" ]] && echo 2 || echo 1)"

  if [[ -n "$SANDBOX_CTID" ]]; then
    SETTINGS_YAML+="
  Sandbox:
    style: row
    columns: 1"
  fi

  # Tools group layout — present whenever filebrowser will be installed on
  # at least one target. Two-column when both ollama-pi-agent and sandbox
  # are present (typical case), single-column otherwise.
  if (( ! SKIP_FILEBROWSER )); then
    local TOOLS_COLS=0
    [[ -n "$PI_HOST_CTID" ]] && TOOLS_COLS=$((TOOLS_COLS + 1))
    [[ -n "$SANDBOX_CTID" ]] && TOOLS_COLS=$((TOOLS_COLS + 1))
    if (( TOOLS_COLS > 0 )); then
      SETTINGS_YAML+="
  Tools:
    style: row
    columns: $TOOLS_COLS"
    fi
  fi

  if (( DRY_RUN )); then
    printf '[dry-run] would write settings.yaml:\n%s\n' "$SETTINGS_YAML"
  else
    printf '%s\n' "$SETTINGS_YAML" | pct exec "$HOMEPAGE_CTID" -- tee "$CONFIG_DIR/settings.yaml" > /dev/null
  fi

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

  # Drop a systemd override populating HOMEPAGE_ALLOWED_HOSTS. Homepage v0.10+
  # validates the incoming Host header against an allowlist; community-scripts
  # installs don't set one, so the default deployment rejects any access
  # except 'localhost'.
  #
  # We used to set '*' for wildcard, but Homepage 1.13+ with Next.js 16
  # stopped honoring wildcards — the validator requires explicit hostnames.
  # Build the allowlist dynamically from the CT's actual addresses:
  #   homepage / homepage:3000           — MagicDNS hostname (tailnet)
  #   localhost / localhost:3000         — local + port-forward access
  #   127.0.0.1 / 127.0.0.1:3000         — loopback
  #   <LAN-IP> / <LAN-IP>:3000           — direct LAN access
  #   <Tailscale-IP> / <Tailscale-IP>:3000 — tailnet direct-IP access
  # Both with-port and without-port forms cover the case where browsers send
  # 'Host: homepage:3000' (most do) vs 'Host: homepage' (some reverse proxies).
  log "  Populating HOMEPAGE_ALLOWED_HOSTS (explicit list — wildcards broke in Homepage 1.13+)..."

  local HP_LAN_IP HP_TS_IP HP_ALLOWED
  HP_LAN_IP="$(pct exec "$HOMEPAGE_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  HP_TS_IP="$(pct exec "$HOMEPAGE_CTID" -- tailscale ip -4 2>/dev/null | head -1)"

  HP_ALLOWED="homepage,homepage:3000,localhost,localhost:3000,127.0.0.1,127.0.0.1:3000"
  [[ -n "$HP_LAN_IP" ]] && HP_ALLOWED+=",${HP_LAN_IP},${HP_LAN_IP}:3000"
  [[ -n "$HP_TS_IP"  ]] && HP_ALLOWED+=",${HP_TS_IP},${HP_TS_IP}:3000"

  log "    → $HP_ALLOWED"

  run "pct exec $HOMEPAGE_CTID -- bash -lc '
    mkdir -p /etc/systemd/system/homepage.service.d
    cat > /etc/systemd/system/homepage.service.d/allowed-hosts.conf <<DROPIN
[Service]
Environment=\"HOMEPAGE_ALLOWED_HOSTS=$HP_ALLOWED\"
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

# ----- filebrowser -----------------------------------------------------------
# Drag-and-drop web UI for getting files onto the pi host (so pi can read them)
# and the sandbox CT (so docker workloads can use them). Installed on both
# targets by default; either gets skipped if the corresponding CT doesn't
# exist (e.g., --skip-sandbox in bootstrap).
#
# Delegates to addons/setup-filebrowser.sh — that script handles the full
# install (apt-get samba & friends, systemd unit, JSON-auth db, Homepage tile
# registration). We just pass it the target list + the reused admin creds.
configure_filebrowser() {
  log "Configuring filebrowser..."

  # Locate the addon. Two paths:
  #   1. If configure-apps.sh is in a clone of the repo, the sibling addons/
  #      directory has setup-filebrowser.sh next to it.
  #   2. If configure-apps.sh was curl'd as a standalone file (no repo clone),
  #      ../addons/ won't exist. Fall back to fetching from GitHub. This keeps
  #      the "curl just this one file" install path complete.
  local SETUP_FB="$SCRIPT_DIR/../addons/setup-filebrowser.sh"
  if [[ ! -x "$SETUP_FB" ]]; then
    log "  Local sibling addon not found ($SETUP_FB)."
    log "  Fetching from GitHub..."
    local FB_URL="https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-filebrowser.sh"
    SETUP_FB="/tmp/setup-filebrowser-$$.sh"
    if curl -fsSL "$FB_URL" -o "$SETUP_FB" 2>/dev/null && [[ -s "$SETUP_FB" ]]; then
      chmod +x "$SETUP_FB"
      log "    Fetched to $SETUP_FB"
    else
      warn "  Couldn't fetch setup-filebrowser.sh from GitHub."
      warn "  Skipping filebrowser install. The Tools tiles in services.yaml will"
      warn "  point at filebrowser instances that don't exist yet. To install manually:"
      warn "    curl -fsSL $FB_URL -o /root/setup-filebrowser.sh"
      warn "    chmod +x /root/setup-filebrowser.sh"
      warn "    /root/setup-filebrowser.sh --admin-user $ADMIN_USER --admin-password '<12+ char pass>' --skip-homepage-tile"
      return
    fi
  fi

  # Determine which targets to install on. The addon defaults to
  # ollama-pi-agent + sandbox, but we want to skip a target if its CT
  # isn't actually there (instead of letting the addon die).
  local -a FB_ARGS=()
  if [[ -n "$PI_HOST_CTID" ]]; then
    FB_ARGS+=(--target ollama-pi-agent)
  fi
  if [[ -n "$SANDBOX_CTID" ]]; then
    # Use whatever hostname the sandbox CT actually has (sandbox or docker
    # for users mid-rename).
    local sandbox_hn
    sandbox_hn="$(pct config "$SANDBOX_CTID" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    : "${sandbox_hn:=sandbox}"
    FB_ARGS+=(--target "$sandbox_hn")
  fi

  if [[ ${#FB_ARGS[@]} -eq 0 ]]; then
    log "  No targets (neither ollama-pi-agent nor sandbox CT exists) — skipping."
    return
  fi

  # Reuse the admin credentials the user already provided. Same UX as
  # Gitea + OpenWebUI — one credential set across the homelab.
  FB_ARGS+=(--admin-user "$ADMIN_USER" --admin-password "$ADMIN_PASSWORD")

  # Suppress the addon's marker-based Homepage tile registration. We already
  # embedded the filebrowser tiles directly in configure_homepage's
  # services.yaml — letting the addon also register would produce duplicates.
  FB_ARGS+=(--skip-homepage-tile)

  # Pass --dry-run through if configure-apps was invoked that way.
  (( DRY_RUN )) && FB_ARGS+=(--dry-run)

  log "  Delegating to setup-filebrowser.sh with targets: ${FB_ARGS[*]}"
  run "'$SETUP_FB' ${FB_ARGS[*]}"
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
  log "==> Configure apps: Gitea + OpenWebUI + pi (ollama-pi-agent) + Homepage + filebrowser"
  resolve_ctids
  selected gitea       && configure_gitea
  # configure_openwebui only runs if (a) selected and (b) the CT actually
  # exists. Bootstrap-pve.sh's --skip-openwebui makes the CT optional, so
  # we silently skip the config rather than fail when the CT is absent.
  selected openwebui   && [[ -n "$OPENWEBUI_CTID" ]] && configure_openwebui
  selected pi          && configure_pi_host
  selected homepage    && configure_homepage
  # filebrowser auto-targets ollama-pi-agent + sandbox if those CTs exist.
  # Skips silently per-target if a CT is absent. Opt out with --skip-filebrowser
  # or via --only (which excludes it implicitly).
  selected filebrowser && (( ! SKIP_FILEBROWSER )) && configure_filebrowser
  write_summary
  log "==> Done."
}

main "$@"
