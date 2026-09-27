#!/usr/bin/env bash
# =============================================================================
# weekly-report.sh — one weekly mail: is the proxy usable, and is it drifting?
#
# Answers the questions nobody remembers to ask until a user complains:
# does the public endpoint still behave, how much did anyone actually use it,
# is the egress stable this week, and is the pinned proxy version behind
# upstream. Sends through the node's msmtp.
#
# Usage:
#   telemt-weekly-report.sh --to you@example.com [--dry-run]
#   telemt-weekly-report.sh --to you@example.com --install        # Mon 09:00
#   telemt-weekly-report.sh --to you@example.com --install --at 'Fri 18:00'
#
# Upstream releases are reported, never installed: see docs/upstream-tracking.md
# for why a proxy with users on it does not self-upgrade.
# =============================================================================
set -uo pipefail

SINCE="${SINCE:-7 days ago}"
WINDOW_DAYS="${WINDOW_DAYS:-7}"
REPORT_TO="${REPORT_TO:-}"
API="${API:-http://127.0.0.1:9091}"
API_TOKEN_FILE="${API_TOKEN_FILE:-/var/lib/telemt/api-token}"
ENV_FILE="${ENV_FILE:-/etc/telemt/deploy.env}"
REPO_DIR="${REPO_DIR:-/root/mtprotoproxy2026}"
# Repos worth knowing about. The first one is what runs here; the rest are the
# protocol's other implementations, watched for changes that affect WEB.
WATCH_REPOS="${WATCH_REPOS:-telemt/telemt telegramdesktop/tproxy-server scratch-net/telego 9seconds/mtg}"
GHSUB_STATE="${GHSUB_STATE:-}"        # optional: a file/dir ghsub keeps releases in
AT="Mon 09:00"
INSTALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --to) REPORT_TO="${2:-}"; shift 2 ;;
    --at) AT="${2:-}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ "$INSTALL" = 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "run as root to install" >&2; exit 1; }
  [ -n "$REPORT_TO" ] || { echo "--install needs --to" >&2; exit 1; }
  cat > /etc/systemd/system/telemt-weekly-report.service <<EOF
[Unit]
Description=Mail the weekly telemt node report

[Service]
Type=oneshot
Environment=REPORT_TO=$REPORT_TO
ExecStart=$SELF
EOF
  cat > /etc/systemd/system/telemt-weekly-report.timer <<EOF
[Unit]
Description=Weekly telemt node report ($AT)

[Timer]
OnCalendar=$AT
# Send late rather than never if the box was down at the time.
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now telemt-weekly-report.timer
  systemctl --no-pager list-timers telemt-weekly-report.timer | head -3
  exit 0
fi

[ -n "$REPORT_TO" ] || { echo "REPORT_TO is unset (use --to you@example.com)" >&2; exit 1; }

count(){ grep -Eic -- "$1" 2>/dev/null || true; }
TOKEN="$(cat "$API_TOKEN_FILE" 2>/dev/null || true)"
api(){ curl -sS --max-time 8 -H "Authorization: Bearer $TOKEN" "$API$1" 2>/dev/null; }

# ---- 1. availability, through the public endpoint ----------------------------
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
WEB_HOST="${WEB_HOST:-}"; SITE_HOST="${SITE_HOST:-}"
http_code(){ curl -sS -o /dev/null --max-time 15 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
AVAIL=""
[ -n "$WEB_HOST" ] && AVAIL="$AVAIL  https://$WEB_HOST/            $(http_code "https://$WEB_HOST/")   (expect 200, the decoy)\n"
[ -n "$WEB_HOST" ] && AVAIL="$AVAIL  https://$WEB_HOST/nope        $(http_code "https://$WEB_HOST/nope")   (expect a site-like 404)\n"
[ -n "$SITE_HOST" ] && AVAIL="$AVAIL  https://$SITE_HOST/           $(http_code "https://$SITE_HOST/")   (expect the app, not 200 from the decoy)\n"
CERT_DAYS="?"
if [ -n "$WEB_HOST" ] && [ -s "/etc/letsencrypt/live/$WEB_HOST/fullchain.pem" ]; then
  END="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$WEB_HOST/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  [ -n "$END" ] && CERT_DAYS="$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))"
fi

# ---- 2. was it used, and did WEB behave -------------------------------------
WEB_STATUS="$(api /v1/runtime/web/status)"
USAGE="$(printf '%s' "$WEB_STATUS" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)["data"]
except Exception: print("  (control API unavailable)"); raise SystemExit
r = d.get("runtime") or {}
t = r.get("totals") or r
print(f"  lifecycle:               {d.get(\"lifecycle\")}  accepting={(d.get(\"ingress\") or {}).get(\"accepting_connections\")}")
print(f"  tcp accepts:             {(d.get(\"ingress\") or {}).get(\"tcp_accept_total\")}")
for k in ("sessions_created","sessions_closed","sessions_live","streams_opened","streams_rejected","bytes_up","bytes_down"):
    if k in t: print(f"  {k+\":\":24} {t[k]}")
' 2>/dev/null)"
[ -n "$USAGE" ] || USAGE="  (control API unavailable)"
SESSIONS_NOW="$(api /v1/runtime/web/sessions | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)["data"]["sessions"]))
except Exception: print("?")' 2>/dev/null | head -1)"
[ -n "$SESSIONS_NOW" ] || SESSIONS_NOW="?"

# ---- 3. egress stability (the thing that broke in September) ----------------
PROBE_LOG="$(journalctl -u telemt-upstream-probe --since "$SINCE" --no-pager 2>/dev/null)"
TELEMT_LOG="$(journalctl -u telemt --since "$SINCE" --no-pager 2>/dev/null)"
BAD_CYCLES="$(printf '%s\n' "$PROBE_LOG" | count 'probe: dc_failed=')"
EGRESS_MOVES="$(printf '%s\n' "$PROBE_LOG" | count 'telegram egress moved')"
TUN_RECONNECTS="$(journalctl -u 'openvpn*' --since "$SINCE" --no-pager 2>/dev/null | count 'Initialization Sequence Completed')"
TG_TIMEOUTS="$(printf '%s\n' "$TELEMT_LOG" | count 'Connection timeout to')"
TG_NOUPSTREAM="$(printf '%s\n' "$TELEMT_LOG" | count 'No healthy upstreams')"
EGRESS_DEV="$(ip route get 149.154.167.51 2>/dev/null | sed -n '1s/.* dev \([^ ]*\).*/\1/p')"

# ---- 4. version drift -------------------------------------------------------
INSTALLED="$(/usr/local/bin/telemt --version 2>/dev/null | head -1)"
PINNED="${TELEMT_VERSION:-?}"
latest_release(){   # repo -> "tag\tdate\tkeywords found in the notes"
  curl -sS --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
tag = d.get("tag_name") or "?"
when = (d.get("published_at") or "")[:10]
body = (d.get("body") or "")[:4000].lower()
hits = [w for w in ("web","websocket","carrier","security","cve","middle","upstream","faketls") if w in body]
print(f"{tag}\t{when}\t{','.join(hits) or '-'}")
' 2>/dev/null
}
RELEASES=""
for r in $WATCH_REPOS; do
  line="$(latest_release "$r")"
  RELEASES="$RELEASES  $(printf '%-34s %s' "$r" "${line:-(unavailable)}")\n"
done
GHSUB=""
if [ -n "$GHSUB_STATE" ] && [ -e "$GHSUB_STATE" ]; then
  GHSUB="  ghsub state: $(ls -ld "$GHSUB_STATE" | awk '{print $6, $7, $8}')\n"
fi

# ---- 5. hygiene -------------------------------------------------------------
DEPLOYED="$(cat /var/lib/telemt/deployed-commit 2>/dev/null | cut -c1-8 || echo '?')"
ORIGIN="$(git -C "$REPO_DIR" rev-parse --short=8 "origin/$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" 2>/dev/null || echo '?')"
TIMERS="$(systemctl list-timers --no-pager 2>/dev/null | grep -E 'telemt-deploy|certbot|telemt-weekly' | awk '{print "    " $0}' | cut -c1-110)"
REBOOT="$( [ -f /var/run/reboot-required ] && echo 'yes' || echo 'no' )"
DISK="$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
LOAD="$(cut -d' ' -f1-3 /proc/loadavg)"

# ---- compose ----------------------------------------------------------------
ACTION=""
[ "${CERT_DAYS:-99}" != "?" ] && [ "$CERT_DAYS" -lt 21 ] 2>/dev/null && ACTION="$ACTION  * certificate expires in $CERT_DAYS days — check the renewal timer and the deploy hook\n"
[ "${TUN_RECONNECTS:-0}" -gt 20 ] && ACTION="$ACTION  * $TUN_RECONNECTS tunnel reconnects — the egress is flapping again (docs/upstream-path.md)\n"
[ "${EGRESS_MOVES:-0}" -gt 2 ] && ACTION="$ACTION  * $EGRESS_MOVES egress moves — routes are bouncing between tunnels again\n"
[ "$DEPLOYED" != "$ORIGIN" ] && ACTION="$ACTION  * deployed $DEPLOYED but origin has $ORIGIN — a deploy is pending or failing\n"
[ "$REBOOT" = yes ] && ACTION="$ACTION  * reboot required; remember the tunnel routes are laid by the up-script\n"
[ -z "$ACTION" ] && ACTION="  * nothing demanding attention in this window.\n"

SUBJECT="[telemt] weekly: $WEB_HOST, ${BAD_CYCLES} bad cycles, cert ${CERT_DAYS}d, pinned $PINNED"
FROM="$(awk '$1=="from"{print $2; exit}' /etc/msmtprc 2>/dev/null || true)"
BODY="$(cat <<EOF
Node:    $(hostname -s) ($(hostname -I | awk '{print $1}'))
Window:  last $WINDOW_DAYS days
Report:  $(date '+%F %T %Z')

== Availability (through the public endpoint) ==
$(printf '%b' "${AVAIL:-  (no hostnames in $ENV_FILE)}")  certificate:             $CERT_DAYS days left

== WEB usage ==
$USAGE
  sessions right now:      $SESSIONS_NOW

== Egress to Telegram ==
  leaves by:               ${EGRESS_DEV:-unknown}
  probe bad cycles:        $BAD_CYCLES
  egress moves:            $EGRESS_MOVES
  tunnel reconnects:       $TUN_RECONNECTS
  telemt timeouts:         $TG_TIMEOUTS   ("No healthy upstreams": $TG_NOUPSTREAM)

== Versions (reported, never auto-installed) ==
  installed:               ${INSTALLED:-unknown}
  pinned in deploy.env:    $PINNED
  latest upstream releases (repo, tag, date, keywords in the notes):
$(printf '%b' "$RELEASES")$(printf '%b' "$GHSUB")
  A tag ahead of the pinned one is a decision, not an incident: read the notes,
  bump TELEMT_VERSION in a commit, let the deploy apply it. See
  docs/upstream-tracking.md.

== Hygiene ==
  deployed commit:         $DEPLOYED   (origin: $ORIGIN)
  reboot required:         $REBOOT
  disk:                    $DISK
  load:                    $LOAD
  timers:
$TIMERS

== Worth doing ==
$(printf '%b' "$ACTION")
--
tools/weekly-report.sh on $(hostname -s)
EOF
)"

MAIL="$( { [ -n "$FROM" ] && echo "From: $FROM"; echo "To: $REPORT_TO"; echo "Subject: $SUBJECT";
           echo "Date: $(date -R)"; echo "Content-Type: text/plain; charset=UTF-8"; echo;
           printf '%s\n' "$BODY"; } )"

if [ "$DRY_RUN" = 1 ]; then printf '%s\n' "$MAIL"; exit 0; fi
command -v msmtp >/dev/null || { echo "msmtp not found" >&2; exit 1; }
printf '%s\n' "$MAIL" | msmtp -- "$REPORT_TO"
echo "sent to $REPORT_TO: $SUBJECT"
