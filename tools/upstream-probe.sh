#!/usr/bin/env bash
# =============================================================================
# upstream-probe.sh — record episodic loss of the node's path to Telegram.
#
# Spot checks miss this: the proxy stalls for a few minutes (telemt logs
# "Connection timeout to <DC>:443" and marks upstreams unhealthy), then the
# path comes back and a manual test shows 20/20 fine. This probe runs
# continuously and logs only the bad cycles, so the pattern can be read
# afterwards from the journal:
#
#   journalctl -u telemt-upstream-probe --since today
#
# Each bad cycle names which side failed, which decides the diagnosis:
#   dc_failed set, control_failed empty -> filtering of Telegram ranges
#                                          (use_middle_proxy is worth trying)
#   both sets non-empty                 -> the link or the host, not Telegram
#   both empty but load high            -> the box starved the probe itself
# =============================================================================
set -uo pipefail

INTERVAL="${INTERVAL:-30}"          # seconds between cycles
TIMEOUT="${TIMEOUT:-5}"             # per-connect deadline
PORT="${PORT:-443}"
# DC2 (Amsterdam), DC1/DC3 (Miami), DC203 — the ones telemt dials.
DC_IPS="${DC_IPS:-149.154.167.51 149.154.175.50 91.105.192.100}"
# Neutral controls on the same port: Cloudflare and GitHub.
CONTROL_IPS="${CONTROL_IPS:-1.1.1.1 140.82.121.4}"
SUMMARY_EVERY="${SUMMARY_EVERY:-120}"   # cycles; 120 * 30s = hourly

probe(){ timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$PORT" 2>/dev/null; }

cycles=0; dc_bad=0; control_bad=0
echo "probe: started interval=${INTERVAL}s timeout=${TIMEOUT}s dc=[$DC_IPS] control=[$CONTROL_IPS]"
while :; do
  bad_dc=""; bad_control=""
  for ip in $DC_IPS;      do probe "$ip" || bad_dc="$bad_dc $ip"; done
  for ip in $CONTROL_IPS; do probe "$ip" || bad_control="$bad_control $ip"; done
  cycles=$((cycles + 1))

  if [ -n "$bad_dc" ] || [ -n "$bad_control" ]; then
    [ -n "$bad_dc" ] && dc_bad=$((dc_bad + 1))
    [ -n "$bad_control" ] && control_bad=$((control_bad + 1))
    # Load rides along: it separates a real network fault from a starved box.
    echo "probe: dc_failed=[${bad_dc# }] control_failed=[${bad_control# }] load=$(cut -d' ' -f1-3 /proc/loadavg)"
  fi

  if [ "$((cycles % SUMMARY_EVERY))" = 0 ]; then
    echo "probe summary: cycles=$cycles dc_bad_cycles=$dc_bad control_bad_cycles=$control_bad"
  fi
  sleep "$INTERVAL"
done
