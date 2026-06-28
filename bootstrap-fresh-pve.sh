#!/usr/bin/env bash
# bootstrap-fresh-pve.sh — One-command install of TD-Proxmox on a fresh PVE host.
#
# Usage (paste this on a fresh PVE host as root):
#
#   curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh | bash
#
# Optional extras (run after TD-Proxmox bootstrap completes):
#
#   # Install the Founder AI OS layer (Dan Martell's framework as agents)
#   curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh \
#     | bash -s -- --with-founder-os <repo-url>
#
#   # Preview without doing anything
#   curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh \
#     | bash -s -- --dry-run
#
# What it does (in order):
#   1. Verifies we're root on a PVE host
#   2. Installs git (if missing)
#   3. Clones (or pulls latest of) the TD-Proxmox repo to /root/td-proxmox
#   4. Runs automation/bootstrap-pve.sh (creates CTs, joins Tailscale)
#   5. Runs automation/setup-ollama-pi.sh (Ollama + pi install)
#   6. Runs automation/configure-apps.sh (admins, tokens, dashboard)
#   7. (Optional) Clones a Founder AI OS repo and runs its setup
#
# Re-run safety: every step is idempotent. Re-running picks up where it
# left off — re-cloning skips if the repo already exists (does `git pull`
# instead), and the underlying scripts each have their own re-run safety.

set -Eeuo pipefail

# ----- args ------------------------------------------------------------------
DRY_RUN=0
WITH_FOUNDER_OS=""
SKIP_OLLAMA=0
SKIP_CONFIGURE=0
REPO_URL="${TD_REPO_URL:-https://github.com/artofax/td-proxmox.git}"
REPO_DIR="${TD_REPO_DIR:-/root/td-proxmox}"
FOUNDER_OS_DIR="${FOUNDER_OS_DIR:-/root/founder-ai-os}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --with-founder-os) WITH_FOUNDER_OS="${2:-}"; shift 2 ;;
    --skip-ollama)     SKIP_OLLAMA=1; shift ;;
    --skip-configure)  SKIP_CONFIGURE=1; shift ;;
    --repo-url)        REPO_URL="$2"; shift 2 ;;
    --repo-dir)        REPO_DIR="$2"; shift 2 ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[td-bootstrap]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[td-bootstrap]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[td-bootstrap]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

# ----- pre-flight ------------------------------------------------------------
log "TD-Proxmox bootstrap starting."

[[ $EUID -eq 0 ]] || die "Run as root."

if ! command -v pveversion >/dev/null 2>&1; then
  die "This isn't a PVE host (no 'pveversion' command found)."
fi

PVE_VERSION="$(pveversion 2>/dev/null | head -1 | awk -F/ '{print $2}' | awk -F- '{print $1}')"
PVE_MAJOR="${PVE_VERSION%%.*}"
if (( PVE_MAJOR < 9 )); then
  warn "Detected PVE $PVE_VERSION. This stack is tested on PVE 9.x — earlier versions may have repo / debian-12-template / Tailscale quirks."
  read -rp "Continue anyway? (y/N) " yn
  [[ "${yn,,}" == "y" ]] || exit 0
fi

log "  PVE version: $PVE_VERSION"
log "  Repo URL:    $REPO_URL"
log "  Repo dir:    $REPO_DIR"
log "  Founder OS:  ${WITH_FOUNDER_OS:-not requested}"

# ----- 1. Install git --------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  log "Installing git..."
  run "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null"
fi

# ----- 2. Clone or update TD-Proxmox -----------------------------------------
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repo already at $REPO_DIR — pulling latest..."
  run "cd '$REPO_DIR' && git pull --ff-only 2>&1 | sed 's/^/    /'"
else
  log "Cloning $REPO_URL → $REPO_DIR..."
  run "git clone '$REPO_URL' '$REPO_DIR' 2>&1 | sed 's/^/    /'"
fi

cd "$REPO_DIR"

# Sanity-check that automation/ scripts exist
for s in bootstrap-pve.sh setup-ollama-pi.sh configure-apps.sh; do
  [[ -f "automation/$s" ]] || die "Expected automation/$s in repo — clone may have failed or repo structure changed."
done

# ----- 3. Run bootstrap-pve.sh -----------------------------------------------
log "================================================================"
log "Phase 1 — bootstrap-pve.sh (creates 5 CTs, joins them to tailnet)"
log "================================================================"
log "You'll be prompted for: SSH key, Tailscale auth key (REUSABLE), CT root password."
log "Each helper script (gitea, openwebui, etc.) shows a whiptail menu — pick 'Default Install'."
log ""
if (( ! DRY_RUN )); then
  bash automation/bootstrap-pve.sh
else
  printf "[dry-run] bash automation/bootstrap-pve.sh\n"
fi

# ----- 4. Run setup-ollama-pi.sh ---------------------------------------------
if (( SKIP_OLLAMA )); then
  log "Skipping setup-ollama-pi.sh (--skip-ollama)."
else
  log "================================================================"
  log "Phase 2 — setup-ollama-pi.sh (Ollama + pi install)"
  log "================================================================"
  log "You'll do one browser click per ollama-targeted CT (ollama.com device pairing)."
  log ""
  if (( ! DRY_RUN )); then
    bash automation/setup-ollama-pi.sh
  else
    printf "[dry-run] bash automation/setup-ollama-pi.sh\n"
  fi
fi

# ----- 5. Run configure-apps.sh ----------------------------------------------
if (( SKIP_CONFIGURE )); then
  log "Skipping configure-apps.sh (--skip-configure)."
else
  log "================================================================"
  log "Phase 3 — configure-apps.sh (admins, tokens, dashboard)"
  log "================================================================"
  log "You'll be prompted for: admin username, email, password, OpenRouter key."
  log ""
  if (( ! DRY_RUN )); then
    bash automation/configure-apps.sh
  else
    printf "[dry-run] bash automation/configure-apps.sh\n"
  fi
fi

# ----- 6. Optional: Founder AI OS --------------------------------------------
if [[ -n "$WITH_FOUNDER_OS" ]]; then
  log "================================================================"
  log "Phase 4 (optional) — Founder AI OS install"
  log "================================================================"

  if [[ -d "$FOUNDER_OS_DIR/.git" ]]; then
    log "Founder OS repo already at $FOUNDER_OS_DIR — pulling latest..."
    run "cd '$FOUNDER_OS_DIR' && git pull --ff-only 2>&1 | sed 's/^/    /'"
  else
    log "Cloning $WITH_FOUNDER_OS → $FOUNDER_OS_DIR..."
    run "git clone '$WITH_FOUNDER_OS' '$FOUNDER_OS_DIR' 2>&1 | sed 's/^/    /'"
  fi

  cd "$FOUNDER_OS_DIR"

  # Find the entry point (could be at root or under starter-kit/)
  ENTRY=""
  for candidate in setup-founder-os.sh starter-kit/setup-founder-os.sh; do
    if [[ -f "$candidate" ]]; then
      ENTRY="$candidate"
      break
    fi
  done
  [[ -n "$ENTRY" ]] || die "No setup-founder-os.sh found in $FOUNDER_OS_DIR"

  log "Running Founder OS setup (phase 1 — Chief + Auditor only)..."
  if (( ! DRY_RUN )); then
    bash "$ENTRY" --phase 1
  else
    printf "[dry-run] bash %s --phase 1\n" "$ENTRY"
  fi
fi

# ----- 7. Done banner --------------------------------------------------------
log "================================================================"
log "==> Done."
log " "
log "What's running:"
log "  - 5 CTs on Tailscale: gitea, openwebui, homepage, sandbox, ollama-pi-agent"
log "  - Ollama + pi installed on ollama-pi-agent (and openwebui if --skip-ollama wasn't set)"
log "  - Gitea, OpenWebUI, Homepage all configured with admin accounts"
if [[ -n "$WITH_FOUNDER_OS" ]]; then
  log "  - Founder OS Phase 1: The Chief + The Auditor (seed The Chief with content next)"
fi
log " "
log "Where to go next:"
log "  - Dashboard:     http://homepage   (everything linked from here)"
log "  - Documentation: cat $REPO_DIR/README.md"
log "  - Optional addons: ls $REPO_DIR/addons/"
log "  - Re-run any step: $REPO_DIR/automation/<script>.sh"
if [[ -z "$WITH_FOUNDER_OS" ]]; then
  log " "
  log "Want the Founder AI OS layer too? Re-run with:"
  log "  curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh \\"
  log "    | bash -s -- --with-founder-os <your-founder-os-repo-url>"
fi
log "================================================================"
