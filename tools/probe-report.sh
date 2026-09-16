#!/usr/bin/env bash
# =============================================================================
# probe-report.sh — mail one report on the node's path to the Telegram DCs.
#
# Reads what telemt-upstream-probe recorded, correlates it with telemt's own
# upstream warnings and with the Telegram bots on this host (independent
# consumers of the same path), samples the current TCP retransmit rate, and
# probes once more live. Sends the result through msmtp.
#
# Usage:
#   telemt-probe-report.sh --to you@example.com            # send now
#   telemt-probe-report.sh --to you@example.com --dry-run  # print, don't send
#   telemt-probe-report.sh --to you@example.com --schedule '2026-09-17 21:00'
#
# --schedule arms a one-shot systemd timer (system timezone) that retires
# itself once it has fired; it survives a reboot and fires late if the box was
# down at the time.
# =============================================================================
set -uo pipefail

SINCE="${SINCE:-24 hours ago}"
WINDOW_HOURS="${WINDOW_HOURS:-24}"
REPORT_TO="${REPORT_TO:-}"
NSTAT_SAMPLE="${NSTAT_SAMPLE:-30}"      # seconds
DC_IPS="${DC_IPS:-149.154.167.51 149.154.175.50 91.105.192.100}"
CONTROL_IPS="${CONTROL_IPS:-1.1.1.1 140.82.121.4}"
SCHEDULE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --to) REPORT_TO="${2:-}"; shift 2 ;;
    --schedule) SCHEDULE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- --schedule: one-shot timer ---------------------------------------------
if [ -n "$SCHEDULE" ]; then
  [ "$(id -u)" = 0 ] || { echo "run as root to schedule" >&2; exit 1; }
  [ -n "$REPORT_TO" ] || { echo "--schedule needs --to" >&2; exit 1; }
  cat > /etc/systemd/system/telemt-probe-report.service <<EOF
[Unit]
Description=Mail the Telegram-path probe report

[Service]
Type=oneshot
Environment=REPORT_TO=$REPORT_TO
ExecStart=$SELF
EOF
  cat > /etc/systemd/system/telemt-probe-report.timer <<EOF
[Unit]
Description=One-shot: mail the Telegram-path probe report at $SCHEDULE

[Timer]
OnCalendar=$SCHEDULE
# Fire late rather than never if the box was down, then retire the timer.
Persistent=true
RemainAfterElapse=no

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now telemt-probe-report.timer
  systemctl --no-pager list-timers telemt-probe-report.timer | head -3
  echo "scheduled for $SCHEDULE ($(date +%Z)), recipient $REPORT_TO"
  exit 0
fi

[ -n "$REPORT_TO" ] || { echo "REPORT_TO is unset (use --to you@example.com)" >&2; exit 1; }

# ---- collect ------------------------------------------------------------------
count(){ grep -c "$1" 2>/dev/null || true; }
jq_probe(){ journalctl -u telemt-upstream-probe --since "$SINCE" --no-pager -o short-iso 2>/dev/null; }
jq_telemt(){ journalctl -u telemt --since "$SINCE" --no-pager -o short-iso 2>/dev/null; }

PROBE_ALL="$(jq_probe)"
BAD="$(printf '%s\n' "$PROBE_ALL" | grep 'probe: dc_failed=' || true)"
BAD_N="$(printf '%s\n' "$BAD" | grep -c 'dc_failed=' || true)"
DC_ONLY="$(printf '%s\n' "$BAD" | grep 'dc_failed=\[[^]]' | grep -vc 'control_failed=\[[^]]' || true)"
BOTH="$(printf '%s\n' "$BAD" | grep 'dc_failed=\[[^]]' | grep -c 'control_failed=\[[^]]' || true)"
CTL_ONLY="$(printf '%s\n' "$BAD" | grep -v 'dc_failed=\[[^]]' | grep -c 'control_failed=\[[^]]' || true)"
EXPECTED_CYCLES=$(( WINDOW_HOURS * 120 ))   # one cycle per 30s
RESTARTS="$(printf '%s\n' "$PROBE_ALL" | count 'probe: started')"
LAST_SUMMARY="$(printf '%s\n' "$PROBE_ALL" | grep 'probe summary' | tail -1)"

TELEMT_LOG="$(jq_telemt)"
TG_TIMEOUTS="$(printf '%s\n' "$TELEMT_LOG" | count 'Connection timeout to')"
TG_UNHEALTHY="$(printf '%s\n' "$TELEMT_LOG" | count 'marked unhealthy')"
TG_NOUPSTREAM="$(printf '%s\n' "$TELEMT_LOG" | count 'No healthy upstreams')"
TG_RECOVERED="$(printf '%s\n' "$TELEMT_LOG" | count 'Upstream recovered')"
TG_PER_IP="$(printf '%s\n' "$TELEMT_LOG" | grep -o 'Connection timeout to [0-9.]*' | sort | uniq -c | sort -rn || true)"

BOTS=""
if command -v docker >/dev/null; then
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ei 'bot' || true); do
    n="$(docker logs --since "${WINDOW_HOURS}h" "$c" 2>&1 | count -iE 'timeout|TelegramNetworkError|ConnectionError')"
    BOTS="$BOTS  $c: $n network-error lines\n"
  done
fi

# Current retransmit/timeout rate: almost all retransmits being RTO-driven means
# packets are being dropped on the path, not congestion-controlled.
NSTAT_NOW=""
if command -v nstat >/dev/null; then
  nstat -n >/dev/null 2>&1
  sleep "$NSTAT_SAMPLE"
  NSTAT_NOW="$(nstat 2>/dev/null | grep -E 'TcpAttemptFails|TcpRetransSegs|TcpExtTCPTimeouts' || echo '  (none in sample)')"
fi

probe_once(){ timeout 5 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null && echo ok || echo FAIL; }
LIVE=""
for ip in $DC_IPS $CONTROL_IPS; do LIVE="$LIVE  $ip $(probe_once "$ip")\n"; done

# ---- verdict ------------------------------------------------------------------
if [ "$BAD_N" = 0 ]; then
  VERDICT="No bad cycles in the window. The path held; the earlier incident was
not reproduced. Nothing to change — keep collecting."
elif [ "$BOTH" -gt "$DC_ONLY" ]; then
  VERDICT="Most bad cycles lost the neutral controls too, so this is the link or
the host, not Telegram filtering. use_middle_proxy would not help: take the
timestamps below to the hosting provider."
else
  VERDICT="Bad cycles hit the Telegram DCs while the neutral controls stayed up,
which is the signature of filtering on Telegram ranges rather than a broken
link. Worth trying use_middle_proxy = true (different endpoints); a node
outside the filtered network is the durable fix."
fi

# ---- compose ------------------------------------------------------------------
SUBJECT="[telemt] Telegram path: $BAD_N bad cycles / ~$EXPECTED_CYCLES on $(hostname -s)"
FROM="$(awk '$1=="from"{print $2; exit}' /etc/msmtprc 2>/dev/null || true)"

BODY="$(cat <<EOF
Node:     $(hostname -f) ($(hostname -I | awk '{print $1}'))
Window:   last $WINDOW_HOURS h (since $(date -d "$SINCE" '+%F %T %Z' 2>/dev/null || echo "$SINCE"))
Report:   $(date '+%F %T %Z')

== Probe (telemt-upstream-probe, one cycle / 30 s) ==
  bad cycles:              $BAD_N of ~$EXPECTED_CYCLES expected
    DCs only:              $DC_ONLY   (controls stayed up)
    DCs + controls:        $BOTH      (link or host)
    controls only:          $CTL_ONLY
  probe restarts:          $RESTARTS
  last hourly summary:     ${LAST_SUMMARY:-(none yet)}

== telemt's own view ==
  "Connection timeout to": $TG_TIMEOUTS
  "marked unhealthy":      $TG_UNHEALTHY
  "No healthy upstreams":  $TG_NOUPSTREAM
  "Upstream recovered":    $TG_RECOVERED
$( [ -n "$TG_PER_IP" ] && printf '  per address:\n%s\n' "$(printf '%s\n' "$TG_PER_IP" | sed 's/^/    /')" )

== Other consumers of the same path (Telegram bots on this host) ==
$(printf '%b' "${BOTS:-  (none found)}")
== Current TCP retransmit rate (${NSTAT_SAMPLE}s sample) ==
$(printf '%s\n' "${NSTAT_NOW:-  (nstat unavailable)}" | sed 's/^/  /')

== Live probe, right now ==
$(printf '%b' "$LIVE")
== Reading ==
$VERDICT

== Last bad cycles (up to 20) ==
$(printf '%s\n' "$BAD" | tail -20 | sed 's/^/  /')

--
Generated by tools/probe-report.sh on $(hostname -s).
Full log: journalctl -u telemt-upstream-probe --since '$SINCE'
EOF
)"

MAIL="$( { [ -n "$FROM" ] && echo "From: $FROM"; \
           echo "To: $REPORT_TO"; \
           echo "Subject: $SUBJECT"; \
           echo "Date: $(date -R)"; \
           echo "Content-Type: text/plain; charset=UTF-8"; \
           echo; \
           printf '%s\n' "$BODY"; } )"

if [ "$DRY_RUN" = 1 ]; then
  printf '%s\n' "$MAIL"
  exit 0
fi
command -v msmtp >/dev/null || { echo "msmtp not found" >&2; exit 1; }
printf '%s\n' "$MAIL" | msmtp -- "$REPORT_TO"
echo "sent to $REPORT_TO: $SUBJECT"
