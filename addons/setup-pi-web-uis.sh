#!/usr/bin/env bash
# setup-pi-web-uis.sh — Install BOTH pi web UIs on ollama-pi-agent:
#
#   Port 9090: VVander/pi-remote-web-ui — agent-aware UI with expandable tool
#              cards, thinking blocks, multi-tab shared session. Uses pi's own
#              AgentSession SDK in-process (the upstream-recommended pattern).
#              https://github.com/VVander/pi-remote-web-ui
#
#   Port 9091: ttyd-wrapped 'ollama launch pi' — plain xterm.js terminal in a
#              browser tab. Same experience as 'pct enter 200 && ollama launch
#              pi' but accessible from any device on the tailnet.
#              https://github.com/tsl0922/ttyd
#
# Both run as systemd services so they auto-start on CT boot, both bind 0.0.0.0
# (Tailscale-reachable via http://ollama-pi-agent:9090 / :9091), both protected
# by the admin user/password you set at install time.
#
# Runs on the PVE host. Targets ollama-pi-agent by default — override with
# --ct-id or --hostname if your CT layout differs.
#
# Usage (zero flags — script prompts for everything it needs):
#   ./setup-pi-web-uis.sh
#
# Or pass any subset:
#   ./setup-pi-web-uis.sh \
#       --admin-user td \
#       --admin-password 'strong-pw' \
#       --cards-port 9090 \
#       --term-port  9091
#
# Optional flags:
#   --ct-id N        Target CT by ID (default: hostname lookup)
#   --hostname X     Hostname to look up (default: ollama-pi-agent)
#   --cards-port N   pi-remote-web-ui port (default: 9090)
#   --term-port  N   ttyd port (default: 9091)
#   --only cards     Install only the cards UI (skip ttyd)
#   --only terminal  Install only ttyd (skip cards UI)
#   --dry-run        Preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
TARGET_HOSTNAME="ollama-pi-agent"
TARGET_CTID=""
CARDS_PORT=9090
TERM_PORT=9091
CARDS_REPO="https://github.com/VVander/pi-remote-web-ui.git"
CARDS_DIR="/opt/pi-remote-web-ui"
ADMIN_USER=""
ADMIN_PASSWORD=""
ONLY=""
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ct-id)          TARGET_CTID="$2"; shift 2 ;;
    --hostname)       TARGET_HOSTNAME="$2"; shift 2 ;;
    --cards-port)     CARDS_PORT="$2"; shift 2 ;;
    --term-port)      TERM_PORT="$2"; shift 2 ;;
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --only)           ONLY="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-pi-web-uis]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-pi-web-uis]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-pi-web-uis]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."
command -v pct >/dev/null || die "pct not found — run this on the PVE host."

find_ct_by_hostname() {
  local want="$1" c hn
  for c in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    hn="$(pct config "$c" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    [[ "$hn" == "$want" ]] && { echo "$c"; return 0; }
  done
  return 1
}

selected() {
  local key="$1"
  if [[ -z "$ONLY" ]]; then return 0; fi
  IFS=',' read -ra wanted <<< "$ONLY"
  for w in "${wanted[@]}"; do [[ "$w" == "$key" ]] && return 0; done
  return 1
}

# ----- resolve admin credentials --------------------------------------------
resolve_admin_user() {
  if [[ -n "$ADMIN_USER" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_USER="dryrun"; log "Dry-run: using placeholder admin user."; return; fi
  printf "\n\033[1;36m[setup-pi-web-uis]\033[0m Admin username for both pi web UIs (e.g. td): " >&2
  IFS= read -r ADMIN_USER
  [[ -n "$ADMIN_USER" ]] || die "Admin user can't be empty."
}

resolve_admin_password() {
  if [[ -n "$ADMIN_PASSWORD" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw"; log "Dry-run: using placeholder admin password."; return; fi
  local pw1 pw2
  printf "\n\033[1;36m[setup-pi-web-uis]\033[0m Admin password (hidden; min 8 chars): " >&2
  IFS= read -rs pw1; echo >&2
  printf "Confirm: " >&2
  IFS= read -rs pw2; echo >&2
  [[ "$pw1" == "$pw2"  ]] || die "Passwords didn't match."
  [[ ${#pw1} -ge 8     ]] || die "Password too short (need >= 8 chars)."
  ADMIN_PASSWORD="$pw1"
}

# ----- resolve target CT ----------------------------------------------------
if [[ -z "$TARGET_CTID" ]]; then
  TARGET_CTID="$(find_ct_by_hostname "$TARGET_HOSTNAME" 2>/dev/null || true)"
fi
[[ -n "$TARGET_CTID" ]] || die "Couldn't find a CT with hostname '$TARGET_HOSTNAME'. Pass --ct-id <n> if it's named differently."
pct status "$TARGET_CTID" 2>/dev/null | grep -q "status: running" \
  || die "CT $TARGET_CTID is not running."
log "Using CT $TARGET_CTID ($TARGET_HOSTNAME)."

resolve_admin_user
resolve_admin_password

# ----- prereqs (Node, git, ttyd) --------------------------------------------
# ttyd isn't in Debian 12's default repos (was dropped between releases). The
# project publishes static musl binaries on GitHub releases; we use those.
log "Installing prereqs (git, build-essential) via apt..."
run "pct exec $TARGET_CTID -- bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git build-essential curl'"

if pct exec "$TARGET_CTID" -- bash -lc 'command -v ttyd' >/dev/null 2>&1; then
  log "ttyd already installed."
else
  log "Installing ttyd from GitHub releases (static musl binary)..."
  run "pct exec $TARGET_CTID -- bash -lc '
    set -e
    arch=\$(uname -m)
    case \"\$arch\" in
      x86_64)  ttyd_arch=x86_64 ;;
      aarch64) ttyd_arch=aarch64 ;;
      armv7l)  ttyd_arch=armhf ;;
      *) echo \"Unsupported architecture for ttyd binary: \$arch\" >&2; exit 1 ;;
    esac
    curl -fsSL \"https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.\${ttyd_arch}\" -o /usr/local/bin/ttyd
    chmod +x /usr/local/bin/ttyd
    /usr/local/bin/ttyd --version 2>&1 | head -1
  '"
fi

# pi installed by setup-ollama-pi.sh drops a standalone Node under
# /root/.local/share/pi-node/node-v.../bin. We reuse that for the cards UI
# build/runtime so we don't have to bring in a second Node installation.
PI_NODE_BIN="$(pct exec "$TARGET_CTID" -- bash -lc 'ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | head -1' 2>/dev/null || true)"
if [[ -z "$PI_NODE_BIN" ]]; then
  warn "Couldn't find pi's Node install. Has setup-ollama-pi.sh been run? Continuing — will fall back to system node if available."
fi

# ----- 1. CARDS UI (VVander/pi-remote-web-ui) ------------------------------
install_cards_ui() {
  log "==================================================================="
  log " Installing cards UI (pi-remote-web-ui) at $CARDS_DIR, port $CARDS_PORT"
  log "==================================================================="

  # Clone or pull
  if pct exec "$TARGET_CTID" -- test -d "$CARDS_DIR/.git" 2>/dev/null; then
    log "  Repo already cloned — fetching latest main."
    run "pct exec $TARGET_CTID -- bash -lc 'cd $CARDS_DIR && git fetch --depth 1 origin main && git reset --hard origin/main'"
  else
    log "  Cloning $CARDS_REPO into $CARDS_DIR..."
    run "pct exec $TARGET_CTID -- git clone --depth 1 '$CARDS_REPO' '$CARDS_DIR'"
  fi

  # Patch the server bind address + port. VVander's default is 127.0.0.1:8080
  # (SSH-tunnel security model); we bind 0.0.0.0:$CARDS_PORT instead so it's
  # reachable as http://ollama-pi-agent:$CARDS_PORT over MagicDNS — matches
  # the rest of our stack which is on the tailnet trust boundary.
  log "  Patching server to bind 0.0.0.0:$CARDS_PORT..."
  run "pct exec $TARGET_CTID -- bash -lc '
    set -e
    cd $CARDS_DIR/server
    # Save originals on first patch, restore-then-patch on re-run.
    [[ -f index.ts.orig ]] || cp index.ts index.ts.orig
    cp index.ts.orig index.ts
    sed -i \"s/127\\.0\\.0\\.1/0.0.0.0/g\" index.ts
    sed -i \"s/\\b8080\\b/$CARDS_PORT/g\" index.ts
  '"

  # npm install + build using pi's standalone Node
  log "  Running npm install + build (this can take a minute)..."
  local NODE_PATH_PREFIX=""
  if [[ -n "$PI_NODE_BIN" ]]; then
    NODE_PATH_PREFIX="export PATH=\"$PI_NODE_BIN:\$PATH\"; "
  fi
  run "pct exec $TARGET_CTID -- bash -lc '${NODE_PATH_PREFIX}cd $CARDS_DIR && npm install --silent && npm run build && npm run build:server'"

  # Systemd unit
  log "  Installing systemd unit pi-cards.service..."
  local NODE_BIN_FOR_UNIT="$PI_NODE_BIN/node"
  [[ -z "$PI_NODE_BIN" ]] && NODE_BIN_FOR_UNIT="/usr/bin/node"
  run "pct exec $TARGET_CTID -- bash -c 'cat > /etc/systemd/system/pi-cards.service <<UNIT
[Unit]
Description=pi-remote-web-ui (cards UI for pi)
After=network.target

[Service]
Type=simple
WorkingDirectory=$CARDS_DIR
ExecStart=$NODE_BIN_FOR_UNIT dist-server/index.js
Environment=NODE_ENV=production
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT'"

  run "pct exec $TARGET_CTID -- systemctl daemon-reload"
  run "pct exec $TARGET_CTID -- systemctl enable --now pi-cards.service"

  log "  Cards UI: http://$TARGET_HOSTNAME:$CARDS_PORT"
  log "  Note: VVander's UI doesn't have built-in auth; rely on tailnet ACLs"
  log "  to restrict who can hit port $CARDS_PORT. (You're not exposing this"
  log "  to the public internet — it lives on your tailnet.)"
}

# ----- 2. TERMINAL UI (ttyd) -----------------------------------------------
install_terminal_ui() {
  log "==================================================================="
  log " Installing terminal UI (ttyd-wrapped pi) on port $TERM_PORT"
  log "==================================================================="

  # ttyd was installed in the apt prereq step. The systemd service wraps
  # 'ollama launch pi' in a writable browser terminal with basic auth.
  log "  Installing systemd unit pi-term.service..."
  run "pct exec $TARGET_CTID -- bash -c 'cat > /etc/systemd/system/pi-term.service <<UNIT
[Unit]
Description=ttyd serving pi in a browser terminal
After=network.target

[Service]
Type=simple
# -W : writable (allow user input)
# -p : port to bind
# -c : basic auth user:pass
# -t titleFixed : set the browser tab title
# bash -lc to make sure /usr/local/bin (Ollama, pi) is on PATH
ExecStart=/usr/local/bin/ttyd -W -p $TERM_PORT -c $ADMIN_USER:$ADMIN_PASSWORD -t titleFixed=\"pi terminal\" bash -lc \"ollama launch pi\"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT'"

  run "pct exec $TARGET_CTID -- systemctl daemon-reload"
  run "pct exec $TARGET_CTID -- systemctl enable --now pi-term.service"

  log "  Terminal UI: http://$TARGET_HOSTNAME:$TERM_PORT"
  log "  Login:       $ADMIN_USER / (your password)"
}

# ----- driver --------------------------------------------------------------
selected cards    && install_cards_ui
selected terminal && install_terminal_ui

# ----- verify --------------------------------------------------------------
if (( ! DRY_RUN )); then
  log "Verifying services..."
  for unit in pi-cards pi-term; do
    if pct exec "$TARGET_CTID" -- systemctl is-active "$unit" >/dev/null 2>&1; then
      log "  $unit: running"
    else
      warn "  $unit: NOT running — check 'pct exec $TARGET_CTID -- journalctl -u $unit --no-pager | tail -20'"
    fi
  done
fi

# ----- done ----------------------------------------------------------------
log "==> Done."
log " "
log "  Cards UI:    http://$TARGET_HOSTNAME:$CARDS_PORT   (no auth; tailnet-protected)"
log "  Terminal UI: http://$TARGET_HOSTNAME:$TERM_PORT   (basic auth: $ADMIN_USER / your password)"
log " "
log "Homepage tile snippet (append to /opt/homepage/config/services.yaml):"
log " "
log "    - Pi (Cards):"
log "        href: http://$TARGET_HOSTNAME:$CARDS_PORT"
log "        description: pi agent — tool cards + thinking blocks"
log "        icon: mdi-cards"
log "    - Pi (Terminal):"
log "        href: http://$TARGET_HOSTNAME:$TERM_PORT"
log "        description: pi in a browser terminal"
log "        icon: mdi-console"
