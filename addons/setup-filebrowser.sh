#!/usr/bin/env bash
# setup-filebrowser.sh — Install filebrowser on ollama-pi-agent so you can
# drag-and-drop files into /root/uploads/ from a browser tab, and pi can pick
# them up immediately without any scp / rsync gymnastics.
#
# Runs on the PVE host. filebrowser is a single 20 MB Go binary with a built-in
# web UI (drag-drop upload, folder navigation, preview, edit text, auth).
# Project: https://github.com/filebrowser/filebrowser
#
# Usage (zero flags — script prompts for everything it needs):
#   ./setup-filebrowser.sh
#
# Or pass any subset:
#   ./setup-filebrowser.sh \
#       --admin-user td \
#       --admin-password 'strong-pw' \
#       --root /root/uploads \
#       --port 8080
#
# Optional flags:
#   --ct-id 200        Target a CT by ID instead of hostname lookup
#   --hostname X       Target a CT by hostname (default: ollama-pi-agent)
#   --root <path>      Filesystem root the UI exposes (default: /root/uploads)
#   --port <n>         Listen port inside the CT (default: 8080)
#   --dry-run          Preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
TARGET_HOSTNAME="ollama-pi-agent"
TARGET_CTID=""
FB_ROOT="/root/uploads"
FB_PORT=8080
ADMIN_USER=""
ADMIN_PASSWORD=""
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ct-id)          TARGET_CTID="$2"; shift 2 ;;
    --hostname)       TARGET_HOSTNAME="$2"; shift 2 ;;
    --root)           FB_ROOT="$2"; shift 2 ;;
    --port)           FB_PORT="$2"; shift 2 ;;
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-filebrowser]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-filebrowser]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-filebrowser]\033[0m %s\n" "$*" >&2; exit 1; }
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

# ----- resolve admin credentials --------------------------------------------
resolve_admin_user() {
  if [[ -n "$ADMIN_USER" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_USER="dryrun"; log "Dry-run: using placeholder admin user."; return; fi
  printf "\n\033[1;36m[setup-filebrowser]\033[0m Admin username for filebrowser (e.g. td): " >&2
  IFS= read -r ADMIN_USER
  [[ -n "$ADMIN_USER" ]] || die "Admin user can't be empty."
}

resolve_admin_password() {
  if [[ -n "$ADMIN_PASSWORD" ]]; then return; fi
  if (( DRY_RUN )); then ADMIN_PASSWORD="dryrun-placeholder-pw"; log "Dry-run: using placeholder admin password."; return; fi
  local pw1 pw2
  printf "\n\033[1;36m[setup-filebrowser]\033[0m Admin password (hidden; min 8 chars): " >&2
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

# ----- 1. install filebrowser inside the CT ---------------------------------
if pct exec "$TARGET_CTID" -- bash -lc 'command -v filebrowser' >/dev/null 2>&1; then
  log "filebrowser already installed."
else
  log "Installing filebrowser via the official one-liner..."
  # The official installer drops the binary at /usr/local/bin/filebrowser.
  run "pct exec $TARGET_CTID -- bash -lc 'apt-get update -qq && apt-get install -y -qq curl && curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash'"
fi

# ----- 2. ensure the file root exists --------------------------------------
log "Ensuring file root exists: $FB_ROOT"
run "pct exec $TARGET_CTID -- mkdir -p '$FB_ROOT'"
run "pct exec $TARGET_CTID -- chmod 750 '$FB_ROOT'"

# ----- 3. initialize the filebrowser DB ------------------------------------
log "Initializing filebrowser database..."
run "pct exec $TARGET_CTID -- bash -lc '
  mkdir -p /etc/filebrowser
  cd /etc/filebrowser
  if [[ ! -f filebrowser.db ]]; then
    filebrowser config init -d /etc/filebrowser/filebrowser.db
  fi
  filebrowser config set \
    -a 0.0.0.0 \
    -p $FB_PORT \
    -r $FB_ROOT \
    --auth.method=json \
    --branding.name=\"TD Homelab Files\" \
    --branding.disableExternal \
    -d /etc/filebrowser/filebrowser.db >/dev/null
'"

# ----- 4. create or update admin user --------------------------------------
log "Creating/updating admin user '$ADMIN_USER'..."
run "pct exec $TARGET_CTID -- bash -lc '
  if filebrowser users find $ADMIN_USER -d /etc/filebrowser/filebrowser.db >/dev/null 2>&1; then
    filebrowser users update $ADMIN_USER --password \"$ADMIN_PASSWORD\" -d /etc/filebrowser/filebrowser.db >/dev/null
  else
    filebrowser users add $ADMIN_USER \"$ADMIN_PASSWORD\" --perm.admin -d /etc/filebrowser/filebrowser.db >/dev/null
  fi
'"

# ----- 5. systemd service so filebrowser auto-starts -----------------------
log "Installing systemd unit..."
run "pct exec $TARGET_CTID -- bash -c 'cat > /etc/systemd/system/filebrowser.service <<UNIT
[Unit]
Description=filebrowser
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/filebrowser -d /etc/filebrowser/filebrowser.db
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT'"

run "pct exec $TARGET_CTID -- systemctl daemon-reload"
run "pct exec $TARGET_CTID -- systemctl enable --now filebrowser"

# ----- 6. verify -----------------------------------------------------------
CT_IP=""
if (( ! DRY_RUN )); then
  log "Verifying service is up..."
  CT_IP="$(pct exec "$TARGET_CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
  if pct exec "$TARGET_CTID" -- bash -lc "exec 3<>/dev/tcp/127.0.0.1/$FB_PORT" 2>/dev/null; then
    log "filebrowser is listening on $CT_IP:$FB_PORT"
  else
    warn "filebrowser isn't responding on $FB_PORT — check 'pct exec $TARGET_CTID -- journalctl -u filebrowser --no-pager | tail -20'"
  fi
fi

# ----- done ---------------------------------------------------------------
log "==> Done."
log " "
log "  Open:   http://$TARGET_HOSTNAME:$FB_PORT  (over Tailscale MagicDNS)"
log "  Or:     http://$(pct exec "$TARGET_CTID" -- hostname -I 2>/dev/null | awk '{print $1}'):$FB_PORT  (LAN)"
log "  Login:  $ADMIN_USER / (your password)"
log "  Files land at: $FB_ROOT/  (inside CT $TARGET_CTID)"
log " "
log "To add a tile to Homepage's dashboard, append to /opt/homepage/config/services.yaml"
log "(or wherever your homepage config lives) under your preferred group:"
log " "
log "    - Files:"
log "        href: http://$TARGET_HOSTNAME:$FB_PORT"
log "        description: Drop files for pi to use"
log "        icon: filebrowser.png"
