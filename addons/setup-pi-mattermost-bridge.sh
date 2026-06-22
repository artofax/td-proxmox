#!/usr/bin/env bash
# setup-pi-mattermost-bridge.sh — Bidirectional pi ↔ Mattermost bridge.
#
# Wraps the @whonixnetworks/pi-mattermost npm package + local patches +
# systemd service so a pi session running on ollama-pi-agent can be DRIVEN
# from a Mattermost channel — user types in #bot, pi reads it and responds
# in the same channel.
#
# Prerequisites (script will verify):
#   - ollama-pi-agent CT exists, running, and has pi installed
#     (i.e., setup-ollama-pi.sh has finished against this host)
#   - mattermost CT exists with a pi-bot account + #bot channel
#     (i.e., setup-mattermost.sh has finished successfully)
#   - /root/td-tokens.txt has the MATTERMOST_BOT_TOKEN /
#     MATTERMOST_BOT_USER_ID / MATTERMOST_TEAM_ID / MATTERMOST_URL lines
#
# What it does (idempotent at each step):
#   1. Reads MM bot creds from /root/td-tokens.txt
#   2. Resolves pi's node binary path inside ollama-pi-agent
#      (/root/.local/share/pi-node/node-v*/bin/node — version-agnostic)
#   3. Installs @whonixnetworks/pi-mattermost via pi's npm
#      (lands at /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost)
#   4. Applies our 3 local patches to that install — debug logging +
#      PI_MATTERMOST_AUTO_CONNECT env var support
#   5. Writes ~/.config/pi-mattermost/config.toml populated from td-tokens.txt
#   6. Installs the systemd unit at /etc/systemd/system/pi-mattermost.service
#   7. Adds 'export PI_MATTERMOST_AUTO_CONNECT=1' to /root/.bashrc on the
#      pi host so any new pi session connects automatically
#   8. systemctl daemon-reload + enable --now pi-mattermost
#
# Usage:
#   ./setup-pi-mattermost-bridge.sh             # default: install end-to-end
#   ./setup-pi-mattermost-bridge.sh --dry-run   # preview
#   ./setup-pi-mattermost-bridge.sh --uninstall # stop service + remove unit
#                                                # (leaves npm package + patches
#                                                # in place; reinstall via re-run)

set -Eeuo pipefail

# ----- args --------------------------------------------------------------
DRY_RUN=0
UNINSTALL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/pi-mattermost-bridge"
TOKENS_FILE="/root/td-tokens.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers -----------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-pi-mm-bridge]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-pi-mm-bridge]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-pi-mm-bridge]\033[0m %s\n" "$*" >&2; exit 1; }
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

# ----- pre-flight --------------------------------------------------------
PI_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
[[ -n "$PI_CTID" ]] || die "No CT with hostname 'ollama-pi-agent' found. Run bootstrap-pve.sh + setup-ollama-pi.sh first."

MM_CTID="$(find_ct_by_hostname mattermost 2>/dev/null || true)"
[[ -n "$MM_CTID" ]] || die "No CT with hostname 'mattermost' found. Run ./addons/setup-mattermost.sh first."

pct status "$PI_CTID" 2>/dev/null | grep -q "status: running" \
  || die "ollama-pi-agent CT ($PI_CTID) isn't running."
pct status "$MM_CTID" 2>/dev/null | grep -q "status: running" \
  || die "mattermost CT ($MM_CTID) isn't running."

# Read MM credentials. All four are required.
MM_BOT_TOKEN="$(read_token MATTERMOST_BOT_TOKEN || true)"
MM_BOT_USER_ID="$(read_token MATTERMOST_BOT_USER_ID || true)"
MM_TEAM_ID="$(read_token MATTERMOST_TEAM_ID || true)"
MM_URL="$(read_token MATTERMOST_URL || true)"
[[ -z "$MM_URL" ]] && MM_URL="http://mattermost:8065"

if [[ -z "$MM_BOT_TOKEN" || -z "$MM_BOT_USER_ID" || -z "$MM_TEAM_ID" ]]; then
  warn "Mattermost credentials missing from $TOKENS_FILE."
  warn "  Required: MATTERMOST_BOT_TOKEN, MATTERMOST_BOT_USER_ID, MATTERMOST_TEAM_ID"
  warn "  Got:"
  warn "    MATTERMOST_BOT_TOKEN=${MM_BOT_TOKEN:+(set)}"
  warn "    MATTERMOST_BOT_USER_ID=${MM_BOT_USER_ID:+(set)}"
  warn "    MATTERMOST_TEAM_ID=${MM_TEAM_ID:+(set)}"
  die "Re-run ./addons/setup-mattermost.sh to populate these in $TOKENS_FILE first."
fi

log "Pre-flight OK."
log "  ollama-pi-agent: CT $PI_CTID"
log "  mattermost:      CT $MM_CTID"
log "  Bridge URL:      $MM_URL"
log "  Bot user_id:     $MM_BOT_USER_ID"
log "  Team id:         $MM_TEAM_ID"

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling pi-mattermost bridge service..."
  run "pct exec $PI_CTID -- systemctl disable --now pi-mattermost 2>/dev/null || true"
  run "pct exec $PI_CTID -- rm -f /etc/systemd/system/pi-mattermost.service"
  run "pct exec $PI_CTID -- systemctl daemon-reload"
  run "pct exec $PI_CTID -- sed -i '/PI_MATTERMOST_AUTO_CONNECT/d' /root/.bashrc"
  log "Uninstalled. npm package + config + patches left in place — re-install via:"
  log "  $(basename "$0")"
  exit 0
fi

# ----- resolve pi-node path inside the CT --------------------------------
log "Resolving pi's Node binary inside ollama-pi-agent..."
NODE_BIN_DIR="$(pct exec "$PI_CTID" -- bash -lc 'ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | sort -V | tail -1' 2>/dev/null || true)"
if [[ -z "$NODE_BIN_DIR" ]]; then
  die "Couldn't find pi's Node install at /root/.local/share/pi-node/node-v*/bin.
  Was setup-ollama-pi.sh run successfully against ollama-pi-agent?"
fi
NODE_BIN="$NODE_BIN_DIR/node"
NPM_BIN="$NODE_BIN_DIR/npm"
log "  Node bin:  $NODE_BIN"

# Where pi's npm installs globals. Set by pi's npm config to this path.
PKG_DIR="/root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost"

# ----- 1. install (or update) the bridge via pi's npm --------------------
# npm's shebang is '#!/usr/bin/env node'. We wrap in 'bash -lc' so pi-node
# is on PATH (set up by setup-ollama-pi.sh's /etc/profile.d drop-in).
#
# Critical: we install LOCALLY (not -g) into /root/.pi/agent/npm. Reason:
# the bundled patches reference absolute paths under
# /root/.pi/agent/npm/node_modules/@whonixnetworks/pi-mattermost/, so the
# package has to land at that exact location for the patches to find their
# target files. `npm install -g` lands it at
# /root/.local/share/pi-node/node-vXX/lib/node_modules/ — wrong place, patches
# fail to apply.
#
# Doing `cd /root/.pi/agent/npm && npm install pkg` creates a 'local'
# install at node_modules/pkg there, matching the layout the patches expect.
log "Installing @whonixnetworks/pi-mattermost into /root/.pi/agent/npm..."
if (( ! DRY_RUN )); then
  if pct exec "$PI_CTID" -- test -d "$PKG_DIR"; then
    log "  Already installed at $PKG_DIR. Skipping npm install."
    log "  (To bump: pct exec $PI_CTID -- bash -lc 'cd /root/.pi/agent/npm && PATH=$NODE_BIN_DIR:\$PATH npm install @whonixnetworks/pi-mattermost@latest')"
  else
    run "pct exec $PI_CTID -- bash -lc 'mkdir -p /root/.pi/agent/npm && cd /root/.pi/agent/npm && PATH=\"$NODE_BIN_DIR:\$PATH\" npm install @whonixnetworks/pi-mattermost'"
  fi

  # Verify the install landed where the patches expect.
  if ! pct exec "$PI_CTID" -- test -d "$PKG_DIR"; then
    warn "Package didn't land at $PKG_DIR after install."
    warn "  npm root -g for the same invocation reports:"
    pct exec "$PI_CTID" -- bash -lc "PATH=\"$NODE_BIN_DIR:\$PATH\" npm root -g" 2>&1 | sed 's/^/    /' >&2 || true
    warn "  Wherever it landed, the bundled patches won't find their target"
    warn "  files. Investigate the actual install location and either move it,"
    warn "  or symlink it, before proceeding."
    die "Install location mismatch — refusing to proceed."
  fi
else
  printf '[dry-run] would run: pct exec %s -- bash -lc \"cd /root/.pi/agent/npm && npm install @whonixnetworks/pi-mattermost\"\n' "$PI_CTID"
fi

# ----- 2. push + apply our patches ---------------------------------------
# The community-scripts/openwebui-style debian-12 templates have an extremely
# minimal apt footprint — git and patch aren't preinstalled. Both are needed
# for the apply-chain below. Install them now (idempotent; apt no-ops on
# already-installed).
log "Ensuring 'git' and 'patch' are installed in the CT (needed for patch application)..."
run "pct exec $PI_CTID -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git patch >/dev/null'"

log "Pushing patches into the CT..."
run "pct exec $PI_CTID -- mkdir -p /tmp/pi-mm-patches"
for p in "$ASSETS_DIR/patches"/*.patch; do
  [[ -f "$p" ]] || continue
  run "pct push $PI_CTID '$p' /tmp/pi-mm-patches/$(basename "$p") --perms 0644"
done

log "Applying patches (skips any already applied)..."
# Apply chain: git apply → patch -p1 → already-applied detection. Matches
# what the user's apply-patches.sh did. We re-implement inline so the
# script is self-contained (no dependency on the upstream pi-mattermost-setup
# repo being cloned somewhere).
if (( ! DRY_RUN )); then
pct exec "$PI_CTID" -- bash -lc "
  cd '$PKG_DIR' || exit 1
  # Init a throwaway git repo so 'git apply' has something to operate on
  if [ ! -d .git ]; then
    git init -q && git add -A && git -c user.email=patch@local -c user.name=patch commit -q -m 'pristine' >/dev/null
  fi
  for patch in /tmp/pi-mm-patches/*.patch; do
    name=\"\$(basename \"\$patch\")\"
    if git apply --check \"\$patch\" 2>/dev/null; then
      git apply \"\$patch\" && echo \"  ✓ \$name applied via git\"
    elif patch -p1 --dry-run < \"\$patch\" >/dev/null 2>&1; then
      patch -p1 < \"\$patch\" >/dev/null && echo \"  ✓ \$name applied via patch\"
    elif git apply --check --reverse \"\$patch\" 2>/dev/null; then
      echo \"  ⚠ \$name already applied — skipping\"
    else
      echo \"  ✗ \$name FAILED to apply (manual fix needed at $PKG_DIR)\" >&2
    fi
  done
"
fi

# ----- 3. write config.toml ----------------------------------------------
log "Writing /root/.config/pi-mattermost/config.toml..."
run "pct exec $PI_CTID -- mkdir -p /root/.config/pi-mattermost /root/.local/share/pi-mattermost"
# Use 'tee' via stdin so we don't have to wrestle with heredoc-inside-pct-exec
# quoting (the TOML has [section] headers that bash double-quotes mangle).
CONFIG_BODY="$(cat <<EOF
# Generated by setup-pi-mattermost-bridge.sh — re-run the script to refresh.

[mattermost]
url = "$MM_URL"
bot_token = "$MM_BOT_TOKEN"
user_id = "$MM_BOT_USER_ID"
team_id = "$MM_TEAM_ID"
http_port = 4000

[pi]
# Default model the bridge will request from pi sessions. Override per-session
# inside pi itself if needed.
default_model = "gemma4:31b-cloud"

[resources]
max_sessions = 10
session_timeout = 7200

[database]
path = "/root/.local/share/pi-mattermost/sessions.db"

[logging]
# DEBUG surfaces all WebSocket events (with patch 01) — useful during
# initial setup. Drop to INFO once everything's working.
level = "DEBUG"
EOF
)"
if (( ! DRY_RUN )); then
  printf '%s\n' "$CONFIG_BODY" | pct exec "$PI_CTID" -- tee /root/.config/pi-mattermost/config.toml >/dev/null
  pct exec "$PI_CTID" -- chmod 600 /root/.config/pi-mattermost/config.toml
fi

# ----- 4. install the systemd unit ---------------------------------------
log "Installing /etc/systemd/system/pi-mattermost.service..."
# Render the template with our resolved paths
UNIT_BODY="$(sed \
  -e "s|%%NODE_BIN%%|$NODE_BIN|g" \
  -e "s|%%NODE_BIN_DIR%%|$NODE_BIN_DIR|g" \
  -e "s|%%PKG_DIR%%|$PKG_DIR|g" \
  "$ASSETS_DIR/pi-mattermost.service")"

if (( ! DRY_RUN )); then
  printf '%s\n' "$UNIT_BODY" | pct exec "$PI_CTID" -- tee /etc/systemd/system/pi-mattermost.service >/dev/null
fi

# ----- 5. export PI_MATTERMOST_AUTO_CONNECT in /root/.bashrc -------------
log "Ensuring PI_MATTERMOST_AUTO_CONNECT=1 is exported in /root/.bashrc..."
run "pct exec $PI_CTID -- bash -c '
  grep -q PI_MATTERMOST_AUTO_CONNECT /root/.bashrc || \
    echo \"export PI_MATTERMOST_AUTO_CONNECT=1\" >> /root/.bashrc
'"

# ----- 6. start + enable -------------------------------------------------
log "Enabling and starting the pi-mattermost service..."
run "pct exec $PI_CTID -- systemctl daemon-reload"
run "pct exec $PI_CTID -- systemctl enable pi-mattermost"
# restart (not just start) so re-runs pick up new config / unit / patches
run "pct exec $PI_CTID -- systemctl restart pi-mattermost"

# ----- 7. verify ---------------------------------------------------------
if (( ! DRY_RUN )); then
  log "Waiting for HTTP port 4000 inside the CT..."
  for i in {1..15}; do
    pct exec "$PI_CTID" -- bash -lc 'exec 3<>/dev/tcp/127.0.0.1/4000' 2>/dev/null && break
    sleep 1
  done
  if pct exec "$PI_CTID" -- bash -lc 'exec 3<>/dev/tcp/127.0.0.1/4000' 2>/dev/null; then
    log "  ✓ pi-mattermost listening on 127.0.0.1:4000"
  else
    warn "  ✗ pi-mattermost not responding on 4000 after 15s."
    warn "  Inspect: pct exec $PI_CTID -- journalctl -u pi-mattermost --no-pager -n 50"
  fi

  log "Last 10 lines of journal:"
  pct exec "$PI_CTID" -- journalctl -u pi-mattermost --no-pager -n 10 2>/dev/null | sed 's/^/    /' || true
fi

# ----- done --------------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
log "Bridge is now running. To use it:"
log " "
log "  1. Inside any pi session on ollama-pi-agent, the bridge will"
log "     auto-connect on session start (PI_MATTERMOST_AUTO_CONNECT=1)."
log "     Pi posts 'Auto-connecting to Mattermost...' as confirmation."
log " "
log "  2. Each connected pi session gets its own Mattermost channel —"
log "     named after the project path. Type in the channel to send to pi."
log " "
log "  3. To verify end-to-end:"
log "     - In Mattermost UI, find the auto-created channel"
log "     - Post a message there"
log "     - Pi receives it; its response posts back to the same channel"
log " "
log "Service management:"
log "  status:   pct exec $PI_CTID -- systemctl status pi-mattermost"
log "  logs:     pct exec $PI_CTID -- journalctl -u pi-mattermost -f"
log "  restart:  pct exec $PI_CTID -- systemctl restart pi-mattermost"
log "  uninstall: $(basename "$0") --uninstall"
log "================================================================"
