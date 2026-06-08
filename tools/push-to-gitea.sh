#!/usr/bin/env bash
# push-to-gitea.sh — Bulk-create Gitea repos for every subfolder in the
# current directory and push each project's contents.
#
# Typical workflow on this homelab:
#   1. Make a folder locally (say ~/td-repos/) and drop community projects
#      into subfolders inside it (one project per subfolder).
#   2. Drop this script into the same folder.
#   3. Drop the whole folder into the filebrowser web UI — it lands at
#      /root/uploads/td-repos/ on ollama-pi-agent.
#   4. SSH or pct enter into ollama-pi-agent and run:
#        cd /root/uploads/td-repos
#        chmod +x push-to-gitea.sh
#        ./push-to-gitea.sh
#
# What it does, per subfolder:
#   1. If not already a git repo, runs `git init -b main`
#   2. Stages everything and commits (with --allow-empty so no-content repos
#      still get a base commit)
#   3. Creates a matching Gitea repo via the API (HTTP 201 = new, 409 = exists)
#   4. Adds `gitea` as a remote (or rewrites it if already set)
#   5. Pushes the current branch
#
# Authentication: reads /root/.netrc for the gitea login + token (which
# configure-apps.sh seeds on ollama-pi-agent). Override with --token or
# --owner if you'd rather pass them explicitly.
#
# Usage:
#   ./push-to-gitea.sh                    # process subfolders of cwd
#   ./push-to-gitea.sh /path/to/parent    # process subfolders of given dir
#
# Flags:
#   --gitea-url URL     Default: http://gitea:3000
#   --owner NAME        Default: parsed from .netrc, else prompt
#   --token TOKEN       Default: parsed from .netrc, else prompt (hidden)
#   --visibility V      'public' (default) | 'private'
#   --branch NAME       Default branch when initializing (default: main)
#   --commit-msg MSG    Default: 'Initial import'
#   --skip-existing     Skip projects where the Gitea repo already exists
#   --dry-run           Print commands without running them

set -Eeuo pipefail

# ----- defaults --------------------------------------------------------------
GITEA_URL="http://gitea:3000"
OWNER=""
TOKEN=""
VISIBILITY="public"
BRANCH="main"
COMMIT_MSG="Initial import"
SKIP_EXISTING=0
DRY_RUN=0
WORK_DIR=""

# ----- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitea-url)     GITEA_URL="$2"; shift 2 ;;
    --owner)         OWNER="$2"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --visibility)    VISIBILITY="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --commit-msg)    COMMIT_MSG="$2"; shift 2 ;;
    --skip-existing) SKIP_EXISTING=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown arg: $1" >&2; exit 2 ;;
    *) WORK_DIR="$1"; shift ;;
  esac
done

# ----- helpers ---------------------------------------------------------------
log()  { printf "\n\033[1;36m[push-to-gitea]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[push-to-gitea]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[push-to-gitea]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

command -v git  >/dev/null || die "git not found. apt install -y git"
command -v curl >/dev/null || die "curl not found. apt install -y curl"

WORK_DIR="${WORK_DIR:-$(pwd)}"
[[ -d "$WORK_DIR" ]] || die "Directory not found: $WORK_DIR"
cd "$WORK_DIR"

[[ "$VISIBILITY" == "public" || "$VISIBILITY" == "private" ]] \
  || die "--visibility must be 'public' or 'private'."
IS_PRIVATE="false"
[[ "$VISIBILITY" == "private" ]] && IS_PRIVATE="true"

# Parse host:port out of the URL for .netrc lookup (.netrc uses bare hostname)
_netrc_machine() {
  echo "$GITEA_URL" \
    | sed -E 's|https?://||' \
    | cut -d/ -f1 \
    | cut -d: -f1
}

_netrc_lookup() {
  local field="$1" machine="$2"
  [[ -f /root/.netrc ]] || return 1
  awk -v m="$machine" -v f="$field" '
    $1 == "machine" && $2 == m { in_m = 1; next }
    in_m && $1 == "machine"    { in_m = 0 }
    in_m && $1 == f            { print $2; exit }
  ' /root/.netrc 2>/dev/null
}

# ----- resolve credentials --------------------------------------------------
NETRC_MACHINE="$(_netrc_machine)"

if [[ -z "$OWNER" ]]; then
  OWNER="$(_netrc_lookup login "$NETRC_MACHINE" || true)"
fi
if [[ -z "$OWNER" ]]; then
  if (( DRY_RUN )); then
    OWNER="dryrun"
  else
    printf "\n\033[1;36m[push-to-gitea]\033[0m Gitea owner username: " >&2
    IFS= read -r OWNER
    [[ -n "$OWNER" ]] || die "Owner can't be empty."
  fi
fi

if [[ -z "$TOKEN" ]]; then
  TOKEN="$(_netrc_lookup password "$NETRC_MACHINE" || true)"
fi
if [[ -z "$TOKEN" ]]; then
  if (( DRY_RUN )); then
    TOKEN="DRYRUN_TOKEN"
  else
    printf "\n\033[1;36m[push-to-gitea]\033[0m Gitea access token (hidden): " >&2
    IFS= read -rs TOKEN
    echo >&2
    [[ -n "$TOKEN" ]] || die "Token can't be empty."
  fi
fi

log "Working dir:    $WORK_DIR"
log "Gitea URL:      $GITEA_URL"
log "Owner:          $OWNER"
log "Visibility:     $VISIBILITY"
log "Default branch: $BRANCH"

# ----- API: create repo (idempotent on 409 = exists) ------------------------
create_repo_on_gitea() {
  local name="$1"
  if (( DRY_RUN )); then
    printf "[dry-run] would POST /api/v1/user/repos with name=%s\n" "$name"
    return 0
  fi
  local body resp status
  body=$(printf '{"name":"%s","description":"%s","auto_init":false,"private":%s}' \
    "$name" "Imported by push-to-gitea.sh" "$IS_PRIVATE")
  resp=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -X POST "$GITEA_URL/api/v1/user/repos" \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null) || true
  status=$(echo "$resp" | grep -oE 'HTTP_STATUS:[0-9]+' | tail -1 | cut -d: -f2)
  case "$status" in
    201) return 0 ;;  # Created
    409) return 1 ;;  # Already exists
    *)   warn "  Gitea API returned HTTP $status. Body:"; echo "$resp" | sed '/^HTTP_STATUS:/d' >&2; return 2 ;;
  esac
}

# ----- per-project work -----------------------------------------------------
process_project() {
  local proj_dir="$1"
  local proj_name="$(basename "$proj_dir")"

  # Gitea repo names allow alphanumeric + . _ - ; normalize whatever the
  # folder name is to that subset, spaces → hyphens.
  local repo_name
  repo_name="$(echo "$proj_name" | tr ' ' '-' | tr -cs 'A-Za-z0-9._-' '-')"
  repo_name="${repo_name%-}"  # trim trailing -

  echo
  log "=== $proj_name -> Gitea repo: $OWNER/$repo_name ==="

  pushd "$proj_dir" >/dev/null || { warn "  Could not cd into $proj_dir"; return 1; }

  # Initialize git if not already a repo
  if [[ ! -d .git ]]; then
    log "  git init -b $BRANCH"
    run "git init -b $BRANCH >/dev/null"
  fi

  # Set local committer identity if not already set (avoid prompting later)
  if ! git config user.email >/dev/null 2>&1; then
    run "git config user.email '$OWNER@homelab.local'"
  fi
  if ! git config user.name >/dev/null 2>&1; then
    run "git config user.name '$OWNER'"
  fi

  # Stage everything and commit if there are uncommitted changes (or no
  # commits yet)
  if (( ! DRY_RUN )); then
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]] || ! git log --oneline -n 1 >/dev/null 2>&1; then
      log "  git add . && git commit -m '$COMMIT_MSG'"
      run "git add -A"
      run "git commit -m \"$COMMIT_MSG\" --allow-empty >/dev/null"
    else
      log "  Working tree clean and history exists — no new commit needed."
    fi
  else
    printf "[dry-run] would git add + commit if needed\n"
  fi

  # Create the repo on Gitea (idempotent on already-exists)
  local created=0
  if create_repo_on_gitea "$repo_name"; then
    created=1
    log "  Created Gitea repo."
  else
    case $? in
      1)
        if (( SKIP_EXISTING )); then
          log "  Already exists on Gitea — skipping (--skip-existing)."
          popd >/dev/null
          return 0
        fi
        log "  Repo already exists on Gitea — will push to it."
        ;;
      *)
        warn "  Repo create failed — skipping push for safety."
        popd >/dev/null
        return 1
        ;;
    esac
  fi

  # Configure the gitea remote (overwrite any previous setting)
  local remote_url="$GITEA_URL/$OWNER/$repo_name.git"
  if git remote get-url gitea >/dev/null 2>&1; then
    run "git remote set-url gitea '$remote_url'"
  else
    run "git remote add gitea '$remote_url'"
  fi

  # Push current branch. .netrc handles auth automatically (curl + git read it).
  local current_branch
  if (( DRY_RUN )); then
    current_branch="$BRANCH"
  else
    current_branch=$(git branch --show-current 2>/dev/null || echo "$BRANCH")
  fi
  log "  Pushing $current_branch to $remote_url"
  run "git push -u gitea '$current_branch'"

  log "  ✓ Done: $remote_url"
  popd >/dev/null
}

# ----- driver ---------------------------------------------------------------
log "==> Scanning subfolders of $WORK_DIR..."

shopt -s nullglob
declare -a SKIPPED PROCESSED FAILED
for dir in */; do
  dir="${dir%/}"
  case "$dir" in
    .*|node_modules|venv|__pycache__|target|build|dist) SKIPPED+=("$dir"); continue ;;
  esac
  if process_project "$dir"; then
    PROCESSED+=("$dir")
  else
    FAILED+=("$dir")
  fi
done
shopt -u nullglob

echo
log "==> Summary"
log "  Processed:  ${#PROCESSED[@]} project(s)"
for p in "${PROCESSED[@]}"; do log "    ✓ $p"; done
if (( ${#FAILED[@]} > 0 )); then
  log "  Failed:     ${#FAILED[@]} project(s)"
  for p in "${FAILED[@]}"; do log "    ✗ $p"; done
fi
if (( ${#SKIPPED[@]} > 0 )); then
  log "  Skipped:    ${#SKIPPED[@]} folder(s) by name pattern"
  for p in "${SKIPPED[@]}"; do log "    - $p"; done
fi
log "Browse the results at $GITEA_URL/$OWNER"
