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
# Usage:
#   ./configure-apps.sh \
#       --admin-user      td \
#       --admin-email     td@homelab.local \
#       --admin-password  'strong-pass' \
#       --openrouter-key  'sk-or-...'
#
# Optional:
#   --gitea-ctid 202        Override CT IDs if you used non-defaults
#   --openwebui-ctid 100
#   --pi-host-ctid 200      The ollama-pi-agent CT
#   --homepage-ctid 110     The Homepage dashboard CT
#   --only gitea,homepage   Subset of subsystems (gitea, openwebui, pi, homepage)
#   --dry-run

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

[[ -n "$ADMIN_USER"     ]] || die "--admin-user is required."
[[ -n "$ADMIN_EMAIL"    ]] || die "--admin-email is required."
[[ -n "$ADMIN_PASSWORD" ]] || die "--admin-password is required."
[[ -n "$OPENROUTER_KEY" ]] || die "--openrouter-key is required (from openrouter.ai → Keys)."

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
configure_gitea() {
  ct_up "$GITEA_CTID"
  log "Configuring Gitea (CT $GITEA_CTID)..."

  wait_for_port_inside_ct "$GITEA_CTID" 3000 "Gitea"

  # Create admin user (idempotent — Gitea errors if user exists; we ignore that case)
  log "  Creating admin user: $ADMIN_USER"
  run "pct exec $GITEA_CTID -- bash -lc \"sudo -u git gitea admin user create \
        --username '$ADMIN_USER' \
        --password '$ADMIN_PASSWORD' \
        --email    '$ADMIN_EMAIL' \
        --admin \
        --must-change-password=false \
        --config /etc/gitea/app.ini || echo '  (user may already exist)'\""

  # Mint an access token with full scope
  log "  Minting access token (name: pi-agent)..."
  GITEA_TOKEN=""
  if (( ! DRY_RUN )); then
    GITEA_TOKEN="$(pct exec "$GITEA_CTID" -- bash -lc "sudo -u git gitea admin user generate-access-token \
        --username '$ADMIN_USER' \
        --token-name 'pi-agent' \
        --scopes 'all' \
        --config /etc/gitea/app.ini 2>/dev/null | awk -F': ' '/^Access token/{print \$2}'" || true)"
    if [[ -z "$GITEA_TOKEN" ]]; then
      warn "  Token generation returned empty — token may already exist with this name. Re-run with a fresh --token-name or revoke in Gitea UI."
    fi
  else
    GITEA_TOKEN="DRYRUN_GITEA_TOKEN_PLACEHOLDER"
  fi

  # Pick up the CT's IP for downstream use
  GITEA_IP="$(pct exec "$GITEA_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "10.0.0.0")"
  log "  Gitea reachable at: http://$GITEA_IP:3000"
}

# ----- OpenWebUI -------------------------------------------------------------
configure_openwebui() {
  ct_up "$OPENWEBUI_CTID"
  log "Configuring OpenWebUI (CT $OPENWEBUI_CTID)..."

  wait_for_port_inside_ct "$OPENWEBUI_CTID" 8080 "OpenWebUI"

  # All API calls happen inside the CT so we can hit localhost:8080 with no TLS hassle
  exec_ow() { pct exec "$OPENWEBUI_CTID" -- bash -lc "$1"; }

  # 1. Signup — first user becomes admin
  log "  Creating admin user via signup..."
  local SIGNUP_BODY
  SIGNUP_BODY=$(printf '{"name":"%s","email":"%s","password":"%s","profile_image_url":"/user.png"}' \
    "$ADMIN_USER" "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  run "exec_ow 'curl -fsS -X POST http://127.0.0.1:8080/api/v1/auths/signup \
                  -H \"Content-Type: application/json\" \
                  -d '\\\''$SIGNUP_BODY'\\\'' >/tmp/owui_signup.json 2>/tmp/owui_signup.err || true'"

  # 2. Login — get JWT
  log "  Signing in to grab JWT..."
  local OWUI_TOKEN=""
  if (( ! DRY_RUN )); then
    local LOGIN_BODY
    LOGIN_BODY=$(printf '{"email":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
    OWUI_TOKEN="$(pct exec "$OPENWEBUI_CTID" -- bash -lc \
      "curl -fsS -X POST http://127.0.0.1:8080/api/v1/auths/signin \
            -H 'Content-Type: application/json' \
            -d '$LOGIN_BODY' | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"token\",\"\"))' " || true)"
    [[ -n "$OWUI_TOKEN" ]] || warn "  Could not retrieve OpenWebUI JWT — check signup result on the CT."
  else
    OWUI_TOKEN="DRYRUN_OWUI_JWT"
  fi

  # 3. Add OpenRouter as an OpenAI-compatible connection.
  # OpenWebUI's config endpoint takes the whole openai block; we read current, splice ours in, push back.
  if [[ -n "$OWUI_TOKEN" ]]; then
    log "  Adding OpenRouter connection..."
    run "pct exec $OPENWEBUI_CTID -- bash -lc '
      curl -fsS -X POST http://127.0.0.1:8080/api/config/openai \
           -H \"Authorization: Bearer $OWUI_TOKEN\" \
           -H \"Content-Type: application/json\" \
           -d {\"OPENAI_API_BASE_URLS\":[\"https://openrouter.ai/api/v1\"],\"OPENAI_API_KEYS\":[\"$OPENROUTER_KEY\"],\"ENABLE_OPENAI_API\":true}
    '"
  fi

  OWUI_IP="$(pct exec "$OPENWEBUI_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "10.0.0.0")"
  log "  OpenWebUI reachable at: http://$OWUI_IP:8080"
}

# ----- ollama-pi-agent (pi host) --------------------------------------------
configure_pi_host() {
  ct_up "$PI_HOST_CTID"
  log "Seeding pi config on ollama-pi-agent (CT $PI_HOST_CTID)..."

  # Derive gitea hostname inside the tailnet. MagicDNS makes 'gitea' resolve;
  # fall back to the CT's LAN IP otherwise.
  local GITEA_HOST="gitea"
  if (( ! DRY_RUN )) && [[ -n "${GITEA_IP:-}" ]]; then
    GITEA_HOST="$GITEA_IP"
  fi

  # 1. .netrc for Gitea (so `git push` and curl-with-machine work without prompting)
  log "  Writing /root/.netrc with Gitea credentials..."
  run "pct exec $PI_HOST_CTID -- bash -c 'cat > /root/.netrc <<NETRC
machine $GITEA_HOST
  login   $ADMIN_USER
  password ${GITEA_TOKEN:-CHANGEME}
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

  # Restart the service so the new config takes effect. The unit name varies
  # by install method, so we try the most common ones.
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
