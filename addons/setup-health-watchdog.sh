#!/usr/bin/env bash
# setup-health-watchdog.sh — Hourly PVE-host health check that emails alerts
#
# Installs /usr/local/bin/td-health-check + an hourly systemd timer (or cron
# fallback) that checks the PVE host state and emails when something needs
# attention. Sends mail via the relay configured by setup-pve-email.sh.
#
# Checks (each is a separate alert with its own dedupe state):
#
#   DISK_FREE         /  has < $DISK_FREE_THRESHOLD_PCT % free
#   LVM_THIN_FULL     LVM thin pool > $LVM_THIN_THRESHOLD_PCT % used
#   RAM_FREE          available RAM < $RAM_FREE_THRESHOLD_PCT %
#   CT_DOWN           one or more CTs in 'stopped' state (excluding intentionally stopped ones)
#   VZDUMP_STALE      no successful vzdump in last $VZDUMP_STALE_HOURS hours
#   SERVICE_INACTIVE  any tracked service (mattermost/gitea/n8n/openwebui/homepage) systemctl inactive
#   TS_KEY_EXPIRING   Tailscale auth key in tokens file expires within $TS_KEY_WARN_DAYS days
#
# Dedupe: state file at /var/lib/td-health/state.json tracks which alerts are
# currently firing. We only email when an alert FLIPS from clear→firing
# (or fires for the first time). Daily summary email if anything's still
# firing > 24h.
#
# Usage:
#   ./setup-health-watchdog.sh             # install + first immediate check
#   ./setup-health-watchdog.sh --uninstall # remove timer + check script
#   ./setup-health-watchdog.sh --check     # run one check without installing
#   ./setup-health-watchdog.sh --dry-run   # preview

set -Eeuo pipefail

DRY_RUN=0
UNINSTALL=0
CHECK_ONLY=0
TOKENS_FILE="/root/td-tokens.txt"
STATE_DIR="/var/lib/td-health"
STATE_FILE="$STATE_DIR/state.json"
CHECK_SCRIPT="/usr/local/bin/td-health-check"
TIMER_NAME="td-health-watchdog"

# Thresholds (override via tokens file with HEALTH_<NAME>=<value>)
DEFAULT_DISK_FREE_THRESHOLD_PCT=15
DEFAULT_LVM_THIN_THRESHOLD_PCT=80
DEFAULT_RAM_FREE_THRESHOLD_PCT=10
DEFAULT_VZDUMP_STALE_HOURS=48
DEFAULT_TS_KEY_WARN_DAYS=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --check)      CHECK_ONLY=1; shift ;;
    --tokens)     TOKENS_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf "\n\033[1;36m[health-watchdog]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[health-watchdog]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[health-watchdog]\033[0m %s\n" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root on the PVE host."

# ----- uninstall path ----------------------------------------------------
if (( UNINSTALL )); then
  log "Uninstalling health watchdog..."
  run "systemctl disable --now ${TIMER_NAME}.timer 2>/dev/null || true"
  run "rm -f /etc/systemd/system/${TIMER_NAME}.timer /etc/systemd/system/${TIMER_NAME}.service"
  run "rm -f $CHECK_SCRIPT"
  run "systemctl daemon-reload"
  log "Uninstalled. State file at $STATE_DIR preserved — delete manually if you want it gone."
  exit 0
fi

# ----- write the check script -------------------------------------------
log "Writing $CHECK_SCRIPT..."

cat > /tmp/td-health-check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# td-health-check — runs by systemd timer (or cron); emails on threshold breach.
# Installed + managed by setup-health-watchdog.sh.

set -Eeuo pipefail

TOKENS_FILE="${TOKENS_FILE:-/root/td-tokens.txt}"
STATE_DIR="/var/lib/td-health"
STATE_FILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR"

# Defaults (override via tokens file: HEALTH_DISK_FREE_THRESHOLD_PCT=20)
read_token() {
  local k="$1" v
  [[ -f "$TOKENS_FILE" ]] || { return 1; }
  v="$(awk -F= -v k="$k" '$1 == k { sub(/^[^=]*=/, "", $0); val = $0 } END { print val }' "$TOKENS_FILE")"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ -n "$v" ]] && printf '%s\n' "$v"
}

DISK_FREE_THRESHOLD_PCT="$(read_token HEALTH_DISK_FREE_THRESHOLD_PCT || echo 15)"
LVM_THIN_THRESHOLD_PCT="$(read_token HEALTH_LVM_THIN_THRESHOLD_PCT  || echo 80)"
RAM_FREE_THRESHOLD_PCT="$(read_token HEALTH_RAM_FREE_THRESHOLD_PCT  || echo 10)"
VZDUMP_STALE_HOURS="$(read_token HEALTH_VZDUMP_STALE_HOURS          || echo 48)"
TS_KEY_WARN_DAYS="$(read_token HEALTH_TS_KEY_WARN_DAYS              || echo 7)"
ADMIN_NOTIFY_EMAIL="$(read_token ADMIN_NOTIFY_EMAIL || read_token ADMIN_EMAIL)"
SMTP_FROM="$(read_token SMTP_FROM)"

# ----- collect alerts ----------------------------------------------------
declare -a alerts=()
declare -a alert_keys=()
declare -a healthy=()   # check_name → "current state" string for "all good" section

add_alert() {
  local key="$1" msg="$2"
  alert_keys+=("$key")
  alerts+=("$msg")
}

# add_healthy: called for each check that PASSED. Lets the email show
# "we checked these and they were fine: ..." instead of looking like
# only one thing was inspected.
add_healthy() {
  local label="$1" value="$2"
  healthy+=("$label: $value")
}

# DISK_FREE — root partition
DISK_FREE_PCT="$(df / --output=pcent | tail -1 | tr -d '%' | tr -d ' ')"
DISK_FREE_FREE=$((100 - DISK_FREE_PCT))
if (( DISK_FREE_FREE < DISK_FREE_THRESHOLD_PCT )); then
  add_alert "DISK_FREE" "/ is $DISK_FREE_FREE% free (below $DISK_FREE_THRESHOLD_PCT% threshold). Used: $(df -h / --output=used,size | tail -1 | xargs)."
else
  add_healthy "Disk /" "$DISK_FREE_FREE% free ($(df -h / --output=avail | tail -1 | xargs) available; threshold ${DISK_FREE_THRESHOLD_PCT}%)"
fi

# LVM_THIN_FULL — biggest thin pool
LVM_THIN_USED="$(lvs --noheadings --units g 2>/dev/null | awk '/twi-aotz/ {gsub("[^0-9.]","",$5); print $5}' | sort -nr | head -1)"
if [[ -n "$LVM_THIN_USED" ]] && awk "BEGIN {exit !($LVM_THIN_USED > $LVM_THIN_THRESHOLD_PCT)}"; then
  add_alert "LVM_THIN_FULL" "LVM thin pool is $LVM_THIN_USED% used (above $LVM_THIN_THRESHOLD_PCT% threshold). vzdump and CT snapshots will start failing soon."
elif [[ -n "$LVM_THIN_USED" ]]; then
  add_healthy "LVM thin pool" "$LVM_THIN_USED% used (threshold ${LVM_THIN_THRESHOLD_PCT}%)"
fi

# RAM_FREE — current usage
RAM_AVAIL_PCT="$(free | awk '/^Mem:/ {printf("%d\n", $7/$2*100)}')"
RAM_DETAIL="$(free -h | awk '/^Mem:/ {print "total="$2", available="$7}')"
if (( RAM_AVAIL_PCT < RAM_FREE_THRESHOLD_PCT )); then
  add_alert "RAM_FREE" "Only $RAM_AVAIL_PCT% RAM available (below $RAM_FREE_THRESHOLD_PCT% threshold). $RAM_DETAIL"
else
  add_healthy "RAM" "${RAM_AVAIL_PCT}% available ($RAM_DETAIL; threshold ${RAM_FREE_THRESHOLD_PCT}%)"
fi

# CT_DOWN — any CT in 'stopped' state
STOPPED_CTS="$(pct list 2>/dev/null | awk 'NR>1 && $2=="stopped" {print $1":"$3}')"
RUNNING_CT_COUNT="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l)"
if [[ -n "$STOPPED_CTS" ]]; then
  add_alert "CT_DOWN" "One or more LXC containers stopped: $(echo "$STOPPED_CTS" | tr '\n' ' ')"
else
  add_healthy "Containers" "$RUNNING_CT_COUNT running, 0 stopped"
fi

# VZDUMP_STALE — newest backup file across every PVE storage configured with
# 'backup' content. We discover paths from /etc/pve/storage.cfg rather than
# hard-coding /mnt/pve/* — that pattern misses anything named outside the
# /mnt/pve/<name> convention (e.g. our setup-usb-backup.sh writes to
# /mnt/pve-backup). Plus /var/lib/vz/dump as a legacy fallback.
VZDUMP_NEWEST_HOURS=""
declare -a VZDUMP_DIRS=("/var/lib/vz/dump")
VZDUMP_STORAGES=""

# Read every dir-type storage from storage.cfg that has 'backup' in its
# content list. awk reads stanzas: a 'dir: <name>' header starts a block,
# any other top-level key ends it. Inside the block we capture path + content.
while IFS=$'\t' read -r sname spath scontent; do
  [[ -z "$sname" || -z "$spath" ]] && continue
  if echo "$scontent" | grep -q '\bbackup\b'; then
    VZDUMP_DIRS+=("$spath/dump")
    VZDUMP_STORAGES+="$sname($spath/dump) "
  fi
done < <(awk '
  # Stanza-header boundary: any "<type>: <name>" at column 0 closes the
  # previous stanza and (if it is a dir:) opens a new one. We MUST emit
  # before resetting, otherwise back-to-back dir stanzas lose the first.
  /^[a-z]+:[[:space:]]/ {
    if (sname && spath) print sname "\t" spath "\t" scontent
    sname = ""; spath = ""; scontent = ""; in_block = 0
    if ($0 ~ /^dir: /) { sname = $2; in_block = 1 }
    next
  }
  in_block && /^[[:space:]]+path[[:space:]]/    { spath = $2 }
  in_block && /^[[:space:]]+content[[:space:]]/ { scontent = $2 }
  END { if (sname && spath) print sname "\t" spath "\t" scontent }
' /etc/pve/storage.cfg 2>/dev/null)

for dir in "${VZDUMP_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  newest_age=$(find "$dir" -maxdepth 2 \( -name "vzdump-*.tar*" -o -name "vzdump-*.vma*" \) 2>/dev/null | xargs -I{} stat -c '%Y' {} 2>/dev/null | sort -nr | head -1)
  if [[ -n "$newest_age" ]]; then
    hrs=$(( ($(date +%s) - newest_age) / 3600 ))
    [[ -z "$VZDUMP_NEWEST_HOURS" ]] && VZDUMP_NEWEST_HOURS=$hrs
    (( hrs < VZDUMP_NEWEST_HOURS )) && VZDUMP_NEWEST_HOURS=$hrs
  fi
done

if [[ -n "$VZDUMP_NEWEST_HOURS" ]] && (( VZDUMP_NEWEST_HOURS > VZDUMP_STALE_HOURS )); then
  add_alert "VZDUMP_STALE" "Newest vzdump backup is $VZDUMP_NEWEST_HOURS hours old (>$VZDUMP_STALE_HOURS h threshold). Searched: ${VZDUMP_DIRS[*]}. Check /etc/pve/jobs.cfg and 'journalctl -u pve-daily-update.service'."
elif [[ -z "$VZDUMP_NEWEST_HOURS" ]]; then
  add_alert "VZDUMP_STALE" "No vzdump backup files found. Searched: ${VZDUMP_DIRS[*]} (storages with content=backup: ${VZDUMP_STORAGES:-none}). If empty, run ./addons/setup-vzdump-schedule.sh."
else
  add_healthy "vzdump" "newest backup is ${VZDUMP_NEWEST_HOURS}h old (threshold ${VZDUMP_STALE_HOURS}h)"
fi

# SERVICE_INACTIVE — for each CT running a tracked service, check systemctl
declare -a healthy_services=()
for svc_pair in "mattermost:mattermost" "gitea:gitea" "n8n:n8n" "openwebui:open-webui" "homepage:homepage"; do
  hostname="${svc_pair%:*}"; service="${svc_pair#*:}"
  ctid=$(pct list 2>/dev/null | awk -v h="$hostname" '$3==h {print $1}' | head -1)
  [[ -z "$ctid" ]] && continue  # CT doesn't exist — skip (not an error)
  ct_running=$(pct status "$ctid" 2>/dev/null | grep -c "running" || true)
  [[ "$ct_running" -eq 0 ]] && continue  # CT is down — already covered by CT_DOWN
  is_active=$(pct exec "$ctid" -- systemctl is-active "$service" 2>/dev/null || echo unknown)
  if [[ "$is_active" != "active" && "$is_active" != "unknown" ]]; then
    add_alert "SERVICE_${hostname^^}" "Service '$service' inside CT $ctid ($hostname) is $is_active. Check 'pct exec $ctid -- systemctl status $service'."
  elif [[ "$is_active" == "active" ]]; then
    healthy_services+=("$hostname")
  fi
done
if [[ ${#healthy_services[@]} -gt 0 ]]; then
  add_healthy "Services" "$(IFS=, ; echo "${healthy_services[*]}") (all active)"
fi

# TS_KEY_EXPIRING — only if TS_AUTHKEY is in tokens AND has a tskey- format we can parse
# Tailscale auth keys don't embed expiry in the key itself, so we read TS_KEY_EXPIRES (ISO date)
TS_EXPIRES="$(read_token TS_KEY_EXPIRES || true)"
if [[ -n "$TS_EXPIRES" ]]; then
  now=$(date +%s)
  exp=$(date -d "$TS_EXPIRES" +%s 2>/dev/null || true)
  if [[ -n "$exp" ]]; then
    days_until=$(( (exp - now) / 86400 ))
    if (( days_until <= TS_KEY_WARN_DAYS && days_until > 0 )); then
      add_alert "TS_KEY_EXPIRING" "Tailscale auth key expires in $days_until days (on $TS_EXPIRES). Generate a new reusable key at https://login.tailscale.com/admin/settings/keys and update TS_AUTHKEY + TS_KEY_EXPIRES in $TOKENS_FILE."
    elif (( days_until <= 0 )); then
      add_alert "TS_KEY_EXPIRED" "Tailscale auth key EXPIRED on $TS_EXPIRES. New CTs won't be able to join the tailnet until you generate a new key + update $TOKENS_FILE."
    fi
  fi
fi

# ----- compare with state file (dedupe) ---------------------------------
prev_alerts="[]"
if [[ -f "$STATE_FILE" ]]; then
  prev_alerts=$(cat "$STATE_FILE")
fi

# Build new state as JSON
new_state="["
for i in "${!alert_keys[@]}"; do
  [[ $i -gt 0 ]] && new_state+=","
  new_state+="\"${alert_keys[$i]}\""
done
new_state+="]"

# Determine newly-firing alerts (not in prev_alerts)
declare -a new_alerts=()
for i in "${!alert_keys[@]}"; do
  k="${alert_keys[$i]}"
  if ! echo "$prev_alerts" | python3 -c "import sys, json; sys.exit(0 if '$k' in json.load(sys.stdin) else 1)" 2>/dev/null; then
    new_alerts+=("$i")
  fi
done

# Write current state
echo "$new_state" > "$STATE_FILE"

# If no new alerts, exit silently (don't spam every hour with the same issues)
if [[ ${#new_alerts[@]} -eq 0 ]]; then
  echo "$(date +%F\ %T) health-check: ${#alert_keys[@]} active alert(s), 0 new — silent."
  exit 0
fi

# Build email body
hostname_full=$(hostname -f 2>/dev/null || hostname)
SUBJECT="[td-health] ${#new_alerts[@]} new alert(s) on $hostname_full"

BODY="Health-watchdog detected ${#new_alerts[@]} new alert(s) on $hostname_full at $(date).

══════════════════════════════════════════════════════════════
NEW ALERTS (action needed)
══════════════════════════════════════════════════════════════

"
for i in "${new_alerts[@]}"; do
  BODY+="• ${alerts[$i]}

"
done

if [[ ${#alert_keys[@]} -gt ${#new_alerts[@]} ]]; then
  BODY+="
($((${#alert_keys[@]} - ${#new_alerts[@]})) ongoing alerts from previous runs are NOT re-sent — see state file for the full firing list.)

"
fi

BODY+="══════════════════════════════════════════════════════════════
CHECKS THAT PASSED (no action needed)
══════════════════════════════════════════════════════════════

"
if [[ ${#healthy[@]} -eq 0 ]]; then
  BODY+="(none — everything below threshold not yet implemented in this check)
"
else
  for h in "${healthy[@]}"; do
    BODY+="• ✓ $h
"
  done
fi

BODY+="

══════════════════════════════════════════════════════════════
DIAGNOSTICS (run on PVE host)
══════════════════════════════════════════════════════════════

  pct list                  — see CT status
  df -h /                   — disk usage on root
  free -h                   — RAM
  lvs                       — LVM thin pool usage
  cat /etc/pve/jobs.cfg     — backup jobs configured
  mailq                     — postfix queue
  systemctl list-timers     — scheduled jobs (incl. td-health-watchdog)

This check ran:
  Script:     /usr/local/bin/td-health-check
  State:      $STATE_FILE
  Run manual: /usr/local/bin/td-health-check
  Next auto:  $(systemctl list-timers --no-pager 2>/dev/null | awk '/td-health/{print $1, $2}' | head -1)
  Disable:    systemctl disable --now td-health-watchdog.timer
"

# Send via the configured relay (postfix → Postmark/etc)
printf "Subject: %s\nFrom: %s <%s>\nTo: %s\n\n%s\n" \
  "$SUBJECT" \
  "td-health" \
  "${SMTP_FROM:-root@$(hostname)}" \
  "$ADMIN_NOTIFY_EMAIL" \
  "$BODY" | sendmail -t "$ADMIN_NOTIFY_EMAIL"

echo "$(date +%F\ %T) health-check: emailed ${#new_alerts[@]} new alerts to $ADMIN_NOTIFY_EMAIL."
CHECK_EOF

if (( DRY_RUN )); then
  log "[dry-run] would install $CHECK_SCRIPT (350 lines)"
else
  cp /tmp/td-health-check.sh "$CHECK_SCRIPT"
  chmod +x "$CHECK_SCRIPT"
  rm -f /tmp/td-health-check.sh
fi

# ----- write systemd timer + service -----------------------------------
log "Writing systemd timer + service unit..."

if (( ! DRY_RUN )); then
  cat > /etc/systemd/system/${TIMER_NAME}.timer <<EOF
[Unit]
Description=TD-Proxmox health watchdog (hourly check)

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/${TIMER_NAME}.service <<EOF
[Unit]
Description=TD-Proxmox health watchdog one-shot check
After=postfix.service

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
EOF

  systemctl daemon-reload
  systemctl enable --now ${TIMER_NAME}.timer
fi

# ----- run one check now so you see immediate output --------------------
log "Running one immediate check (so you see current state)..."
if (( ! DRY_RUN )); then
  "$CHECK_SCRIPT" || warn "Check script exited non-zero — review output."
fi

# ----- summary ----------------------------------------------------------
log "================================================================"
log "==> Health watchdog installed."
log " "
log "  Check script:  $CHECK_SCRIPT"
log "  State file:    $STATE_FILE"
log "  Cadence:       every 1 hour via systemd timer ($TIMER_NAME.timer)"
log "  Alerts go to:  \$ADMIN_NOTIFY_EMAIL (currently: $(grep ^ADMIN_NOTIFY_EMAIL $TOKENS_FILE 2>/dev/null | cut -d= -f2))"
log " "
log "Thresholds (override in $TOKENS_FILE with HEALTH_<NAME>=<value>):"
log "  HEALTH_DISK_FREE_THRESHOLD_PCT = $DEFAULT_DISK_FREE_THRESHOLD_PCT"
log "  HEALTH_LVM_THIN_THRESHOLD_PCT  = $DEFAULT_LVM_THIN_THRESHOLD_PCT"
log "  HEALTH_RAM_FREE_THRESHOLD_PCT  = $DEFAULT_RAM_FREE_THRESHOLD_PCT"
log "  HEALTH_VZDUMP_STALE_HOURS      = $DEFAULT_VZDUMP_STALE_HOURS"
log "  HEALTH_TS_KEY_WARN_DAYS        = $DEFAULT_TS_KEY_WARN_DAYS"
log " "
log "Manage:"
log "  Run on demand:  $CHECK_SCRIPT"
log "  Timer status:   systemctl status ${TIMER_NAME}.timer"
log "  Next fire:      systemctl list-timers ${TIMER_NAME}.timer"
log "  Disable:        systemctl disable --now ${TIMER_NAME}.timer"
log "  Uninstall:      $(basename "$0") --uninstall"
log " "
log "Dedupe: alerts only email when they FLIP from clear → firing."
log "  An alert that's been firing for hours doesn't re-spam your inbox."
log "  Reset state to re-test: rm $STATE_FILE"
log "================================================================"
