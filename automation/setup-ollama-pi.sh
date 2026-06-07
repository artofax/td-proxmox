#!/usr/bin/env bash
# setup-ollama-pi.sh — Sign Ollama in on every relevant LXC, install pi on
# ollama-pi-agent. Runs on the PVE host.
#
# Default behavior (no flags): walks the built-in target list, currently
#   ollama-pi-agent   → install/verify Ollama, signin, pull model, install pi
#   openwebui         → install/verify Ollama, signin, pull model (no pi)
# Idempotent at every step — re-runs only do work that isn't already done.
#
# The one place you leave the terminal is the `ollama signin` step. Ollama
# prints a pairing URL to stdout, blocks while you visit it in a browser
# (logged into ollama.com) and click Connect, then exits naturally. We run
# signin once per target CT, so plan to do two browser clicks on a fresh host.
#
# Usage:
#   ./setup-ollama-pi.sh                          # default: walk all targets
#   ./setup-ollama-pi.sh --model gemma3:31b-cloud # different default model
#   ./setup-ollama-pi.sh --ct-id 200              # single CT (still installs pi if hostname matches a "with-pi" target)
#   ./setup-ollama-pi.sh --ct-id 103 --skip-pi    # explicit single-CT, no pi
#   ./setup-ollama-pi.sh --skip-signin            # install Ollama, pair manually later
#   ./setup-ollama-pi.sh --skip-pi                # never install pi (Ollama on all targets)
#   ./setup-ollama-pi.sh --dry-run                # preview commands

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
DEFAULT_MODEL="gemma3:12b-cloud"
MODEL=""
PI_CTID=""
SKIP_SIGNIN=0
SKIP_PI=0
DRY_RUN=0

# Built-in targets. Format: "hostname:mode" where mode is with-pi or no-pi.
# To add a new CT for community-extensions, append a row here.
DEFAULT_TARGETS=(
  "ollama-pi-agent:with-pi"
  "openwebui:no-pi"
)

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ct-id)       PI_CTID="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --skip-signin) SKIP_SIGNIN=1; shift ;;
    --skip-pi)     SKIP_PI=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${MODEL:=$DEFAULT_MODEL}"

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[setup-ollama-pi]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[setup-ollama-pi]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[setup-ollama-pi]\033[0m %s\n" "$*" >&2; exit 1; }
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

get_hostname_for_ctid() {
  pct config "$1" 2>/dev/null | awk '/^hostname:/ {print $2}'
}

# ----- per-CT operations -----------------------------------------------------

install_ollama_in_ct() {
  local ctid="$1"
  if pct exec "$ctid" -- bash -lc 'command -v ollama' >/dev/null 2>&1; then
    log "  [$ctid] Ollama already installed."
    return
  fi
  log "  [$ctid] Installing curl + zstd + Ollama..."
  run "pct exec $ctid -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl zstd && curl -fsSL https://ollama.com/install.sh | sh'"
}

ollama_signin_in_ct() {
  local ctid="$1" hostname="$2"
  if (( SKIP_SIGNIN )); then
    log "  [$ctid] Skipping ollama signin (--skip-signin set)."
    return
  fi
  if pct exec "$ctid" -- bash -lc 'ollama list 2>/dev/null | tail -n +2 | grep -q .' 2>/dev/null; then
    log "  [$ctid] Ollama appears already paired (models present). Skipping signin."
    return
  fi

  echo
  log "===================================================="
  log " [$hostname] Starting 'ollama signin'."
  log " Ollama will print a URL like:"
  log "   https://ollama.com/connect?name=$hostname&key=..."
  log " Open it in a browser logged into ollama.com, click"
  log " Connect, and this script will resume automatically."
  log "===================================================="
  echo

  if (( DRY_RUN )); then
    printf "[dry-run] pct exec %s -- bash -lc 'ollama signin'\n" "$ctid"
  else
    pct exec "$ctid" -- bash -lc 'ollama signin' \
      || die "  [$ctid] ollama signin failed or cancelled."
  fi
  log "  [$ctid] Pairing complete."
}

pull_model_in_ct() {
  local ctid="$1"
  if (( SKIP_SIGNIN )); then
    log "  [$ctid] Skipping model pull (Ollama not paired yet)."
    return
  fi
  if pct exec "$ctid" -- bash -lc "ollama list 2>/dev/null | awk '\$1==\"$MODEL\"' | grep -q ." 2>/dev/null; then
    log "  [$ctid] Model $MODEL already pulled."
    return
  fi
  log "  [$ctid] Pulling $MODEL (this can take a while)..."
  run "pct exec $ctid -- bash -lc 'ollama pull \"$MODEL\"'"
}

install_pi_in_ct() {
  local ctid="$1"
  if pct exec "$ctid" -- bash -lc 'command -v pi >/dev/null 2>&1 || ls /root/.local/share/pi-node/node-v*/bin/pi >/dev/null 2>&1'; then
    log "  [$ctid] pi already installed."
  else
    log "  [$ctid] Installing pi (auto-answering Y to install Node.js + pi prompts)..."
    run "pct exec $ctid -- bash -lc 'yes | bash -c \"\$(curl -fsSL https://pi.dev/install.sh)\" 2>&1 | tail -40'"
  fi

  log "  [$ctid] Ensuring pi PATH in /root/.bashrc..."
  run "pct exec $ctid -- bash -lc '
    PI_BIN=\$(ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | head -1)
    if [[ -n \"\$PI_BIN\" ]]; then
      if ! grep -qF \"\$PI_BIN\" /root/.bashrc 2>/dev/null; then
        echo \"export PATH=\\\"\$PI_BIN:\\\$PATH\\\"\" >> /root/.bashrc
        echo \"    Added \$PI_BIN to /root/.bashrc\"
      else
        echo \"    PATH export already present in /root/.bashrc\"
      fi
    else
      echo \"    Could not find /root/.local/share/pi-node/node-v*/bin — verify pi installed correctly\"
    fi
  '"
}

# ----- choose targets --------------------------------------------------------
# If --ct-id was passed, build a single-element target list from that CT's
# hostname so the "with-pi" / "no-pi" decision still respects the built-in
# defaults (or --skip-pi when set).
declare -a TARGETS
if [[ -n "$PI_CTID" ]]; then
  pct status "$PI_CTID" 2>/dev/null | grep -q "status: running" \
    || die "CT $PI_CTID is not running."
  hn="$(get_hostname_for_ctid "$PI_CTID")"
  mode="no-pi"
  # If the explicit CT happens to match a built-in "with-pi" target and
  # --skip-pi isn't set, install pi too.
  for entry in "${DEFAULT_TARGETS[@]}"; do
    IFS=':' read -r dh dmode <<< "$entry"
    if [[ "$dh" == "$hn" ]]; then mode="$dmode"; break; fi
  done
  TARGETS=("$hn:$mode")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

# ----- main loop -------------------------------------------------------------
log "==> Targets:"
for entry in "${TARGETS[@]}"; do
  IFS=':' read -r hostname mode <<< "$entry"
  log "     $hostname ($mode)"
done

for entry in "${TARGETS[@]}"; do
  IFS=':' read -r hostname mode <<< "$entry"
  ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
  if [[ -z "$ctid" ]]; then
    warn "No CT with hostname '$hostname' — skipping. Run bootstrap-pve.sh first if this is unexpected."
    continue
  fi
  if ! pct status "$ctid" 2>/dev/null | grep -q "status: running"; then
    warn "CT $ctid ($hostname) is not running — skipping."
    continue
  fi

  echo
  log "============================================================"
  log "  Setting up Ollama on $hostname (CT $ctid)"
  log "============================================================"

  install_ollama_in_ct "$ctid"
  ollama_signin_in_ct  "$ctid" "$hostname"
  pull_model_in_ct     "$ctid"

  if [[ "$mode" == "with-pi" ]] && (( ! SKIP_PI )); then
    install_pi_in_ct "$ctid"
  fi
done

# ----- final verification ---------------------------------------------------
if (( ! DRY_RUN )); then
  log "==> Verification:"
  for entry in "${TARGETS[@]}"; do
    IFS=':' read -r hostname _mode <<< "$entry"
    ctid="$(find_ct_by_hostname "$hostname" 2>/dev/null || true)"
    [[ -z "$ctid" ]] && continue
    log "  [$hostname / CT $ctid]"
    pct exec "$ctid" -- bash -lc 'echo "    ollama: $(command -v ollama || echo not-found)"; ollama list 2>/dev/null | tail -n +2 | head -3 | sed "s/^/    /"; command -v pi >/dev/null && echo "    pi: $(command -v pi)" || true' 2>/dev/null
  done
fi

# ----- done ------------------------------------------------------------------
log "==> All done."
log "    ollama-pi-agent — start pi with:  pct enter <ctid>  &&  ollama launch pi"
log "    openwebui — chat dropdown now lists local Ollama models alongside OpenRouter."
