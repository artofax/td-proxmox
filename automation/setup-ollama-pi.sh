#!/usr/bin/env bash
# setup-ollama-pi.sh — Install Ollama + pi on the ollama-pi-agent LXC.
# Runs on the PVE host. The only non-automatable step is clicking Connect on
# ollama.com — the script prints the URL and waits for you to do that, then
# resumes automatically.
#
# Usage:
#   ./setup-ollama-pi.sh                                  # auto-detect ollama-pi-agent, default model
#   ./setup-ollama-pi.sh --model gemma3:31b-cloud         # different default model
#   ./setup-ollama-pi.sh --ct-id 103 --skip-pi            # target a different CT, no pi install
#   ./setup-ollama-pi.sh --skip-signin                    # install only, pair manually later
#   ./setup-ollama-pi.sh --skip-pi                        # Ollama-only setup (no pi)
#   ./setup-ollama-pi.sh --dry-run                        # preview commands
#
# What it does (in CT 200 by default):
#   1. apt-get update + install curl + zstd
#   2. Install Ollama from official install.sh
#   3. Run `ollama signin` — surfaces the connect URL, waits for your browser click
#   4. ollama pull <model>  (default: gemma3:12b-cloud, configurable via --model)
#   5. Install pi from pi.dev/install.sh, answering Y to all prompts
#   6. Detect /root/.local/share/pi-node/node-v.../bin and append to /root/.bashrc PATH
#   7. Verify pi is on PATH
#
# Idempotent — re-runs skip pieces already in place (Ollama installed, model
# pulled, pi binary present, PATH already exported).

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
PI_CTID=""
DEFAULT_MODEL="gemma3:12b-cloud"
MODEL=""
SKIP_SIGNIN=0
SKIP_PI=0
DRY_RUN=0

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ct-id)       PI_CTID="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --skip-signin) SKIP_SIGNIN=1; shift ;;
    --skip-pi)     SKIP_PI=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
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

# Resolve CT
if [[ -z "$PI_CTID" ]]; then
  PI_CTID="$(find_ct_by_hostname ollama-pi-agent 2>/dev/null || true)"
fi
[[ -n "$PI_CTID" ]] || die "Couldn't find ollama-pi-agent. Pass --ct-id <n> or rename the CT."
pct status "$PI_CTID" 2>/dev/null | grep -q "status: running" || die "CT $PI_CTID is not running."
log "Using CT $PI_CTID for ollama-pi-agent install."

# ----- 1. apt prereqs --------------------------------------------------------
log "Installing curl + zstd (prereqs)..."
run "pct exec $PI_CTID -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl zstd'"

# ----- 2. Ollama -------------------------------------------------------------
if pct exec "$PI_CTID" -- bash -lc 'command -v ollama' >/dev/null 2>&1; then
  log "Ollama already installed — skipping installer."
else
  log "Installing Ollama..."
  run "pct exec $PI_CTID -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'"
fi

# ----- 3. ollama signin ------------------------------------------------------
# This step is interactive only insofar as the user clicks Connect in a browser.
# `ollama signin` itself just blocks on stdout waiting for the cloud to confirm,
# so we let its output stream through to the operator's terminal and wait for it
# to exit on its own.
if (( SKIP_SIGNIN )); then
  log "Skipping ollama signin (--skip-signin set). Pair manually later with: pct exec $PI_CTID -- ollama signin"
elif pct exec "$PI_CTID" -- bash -lc 'ollama list 2>/dev/null | tail -n +2 | grep -q .' 2>/dev/null; then
  log "Ollama appears already paired (models present). Skipping signin."
else
  echo
  log "==================================================="
  log "Starting 'ollama signin'. Read carefully:"
  log " "
  log " 1. Below, Ollama will print a URL like"
  log "    https://ollama.com/connect?name=ollama-pi-agent&key=..."
  log " "
  log " 2. Open it in a browser where you're logged into ollama.com."
  log " 3. Click 'Connect'."
  log " 4. This script will resume automatically once the pairing completes."
  log " "
  log " (Ctrl-C here cancels; you can re-run with --skip-signin to install"
  log "  the rest now and pair Ollama later.)"
  log "==================================================="
  echo

  if (( DRY_RUN )); then
    printf "[dry-run] pct exec %s -- bash -lc 'ollama signin'\n" "$PI_CTID"
  else
    # bash -lc so /usr/local/bin (where Ollama installs) is on PATH.
    pct exec "$PI_CTID" -- bash -lc 'ollama signin' || die "ollama signin failed or was cancelled."
  fi
  log "Pairing complete."
fi

# ----- 4. Pull model ---------------------------------------------------------
if (( SKIP_SIGNIN )); then
  log "Skipping model pull (Ollama isn't paired yet)."
elif pct exec "$PI_CTID" -- bash -lc "ollama list 2>/dev/null | awk '\$1==\"$MODEL\"' | grep -q ." 2>/dev/null; then
  log "Model $MODEL already pulled — skipping."
else
  log "Pulling model $MODEL (this can take a while)..."
  run "pct exec $PI_CTID -- bash -lc 'ollama pull \"$MODEL\"'"
fi

# ----- 5. pi -----------------------------------------------------------------
if (( SKIP_PI )); then
  log "Skipping pi install (--skip-pi set)."
elif pct exec "$PI_CTID" -- bash -lc 'command -v pi >/dev/null 2>&1 || ls /root/.local/share/pi-node/node-v*/bin/pi >/dev/null 2>&1'; then
  log "pi already installed — skipping installer."
else
  log "Installing pi (answering Y to install Node.js + pi prompts)..."
  # The pi installer asks two Y/N questions. `yes` keeps feeding 'y' until the
  # installer is done. We also pass -y in case the installer accepts a flag.
  run "pct exec $PI_CTID -- bash -lc 'yes | bash -c \"\$(curl -fsSL https://pi.dev/install.sh)\" 2>&1 | tail -40'"
fi

# ----- 6. PATH ---------------------------------------------------------------
if (( SKIP_PI )); then
  log "Skipping PATH setup (no pi install)."
else
  log "Setting up pi PATH in /root/.bashrc..."
  run "pct exec $PI_CTID -- bash -lc '
    PI_BIN=\$(ls -d /root/.local/share/pi-node/node-v*/bin 2>/dev/null | head -1)
    if [[ -n \"\$PI_BIN\" ]]; then
      if ! grep -qF \"\$PI_BIN\" /root/.bashrc 2>/dev/null; then
        echo \"export PATH=\\\"\$PI_BIN:\\\$PATH\\\"\" >> /root/.bashrc
        echo \"  Added \$PI_BIN to /root/.bashrc\"
      else
        echo \"  PATH export already present in /root/.bashrc\"
      fi
    else
      echo \"  Could not find /root/.local/share/pi-node/node-v*/bin — verify pi installed correctly\"
    fi
  '"
fi

# ----- 7. Verify -------------------------------------------------------------
if (( ! DRY_RUN )); then
  log "Verifying..."
  pct exec "$PI_CTID" -- bash -lc 'source /root/.bashrc; which ollama; which pi || true; ollama list || true'
fi

# ----- Done ------------------------------------------------------------------
log "==> Done."
if (( SKIP_PI )); then
  log "Ollama is set up on CT $PI_CTID. Verify with: pct exec $PI_CTID -- bash -lc 'ollama list'"
else
  log "To start pi:  pct enter $PI_CTID  &&  ollama launch pi"
  log "First time pi runs, ask it to add OpenRouter as a provider:"
  log "  \"add OpenRouter to your model providers using OPENROUTER_API_KEY from my env\""
fi
