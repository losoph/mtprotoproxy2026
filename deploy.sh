#!/usr/bin/env bash
# =============================================================================
# deploy.sh — pull this repo on the node and re-apply its setup when it changed.
#
# The node's configuration lives in git, not in hand edits: a fix is committed,
# pushed, and the node converges on it. Editing /etc/nginx or /etc/telemt by
# hand puts the box in a state no commit describes — and the next deploy would
# silently overwrite it anyway.
#
# The environment of the original setup run is stored in /etc/telemt/deploy.env
# (written by setup-telemt-web-node.sh), so a deploy replays exactly that
# invocation against the new checkout.
#
# Usage:
#   sudo bash deploy.sh --install     # set up the systemd timer (every 5 min)
#   sudo bash deploy.sh               # apply now if origin has a new commit
#   sudo bash deploy.sh --force       # apply even without a new commit
#   sudo bash deploy.sh --status      # what is deployed, what is pending
#   sudo bash deploy.sh --set USE_MIDDLE_PROXY=1   # change a node parameter + apply
#   journalctl -u telemt-deploy -f    # what the timer did
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ENV_FILE="${ENV_FILE:-/etc/telemt/deploy.env}"
STATE_FILE="${STATE_FILE:-/var/lib/telemt/deployed-commit}"
LOCK_FILE=/var/lock/telemt-deploy.lock
INTERVAL="${INTERVAL:-5min}"          # timer period for --install

log(){ printf '\033[1;36m### %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$REPO_DIR/.git" ] || die "$REPO_DIR is not a git checkout"
BRANCH="${BRANCH:-$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)}"

# ---- --install: systemd timer ------------------------------------------------
install_timer(){
  [ -f "$ENV_FILE" ] || die "$ENV_FILE is missing — run setup-telemt-web-node.sh once first;
    it writes the environment that deploys replay."
  cat > /etc/systemd/system/telemt-deploy.service <<EOF
[Unit]
Description=Pull mtprotoproxy2026 and re-apply the telemt node setup
Documentation=https://github.com/losoph/mtprotoproxy2026
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=BRANCH=$BRANCH
ExecStart=/usr/bin/env bash $REPO_DIR/deploy.sh
EOF
  cat > /etc/systemd/system/telemt-deploy.timer <<EOF
[Unit]
Description=Check mtprotoproxy2026 for new commits

[Timer]
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
# Spread the fetch so a pushed fix doesn't hit GitHub from every node at once.
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now telemt-deploy.timer
  log "timer installed (branch $BRANCH, every $INTERVAL)"
  systemctl --no-pager list-timers telemt-deploy.timer | head -3
}

# ---- fetch -------------------------------------------------------------------
fetch_origin(){
  local delay=2 i
  for i in 1 2 3 4 5; do
    if git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"; then return 0; fi
    [ "$i" = 5 ] && return 1
    sleep "$delay"; delay=$((delay * 2))
  done
}

# ---- apply -------------------------------------------------------------------
apply(){
  local target="$1"
  # Replay the recorded setup invocation. NEW_SECRET is never inherited: a
  # deploy must not rotate secrets and invalidate everyone's links.
  set -a; . "$ENV_FILE"; set +a
  unset NEW_SECRET
  git -C "$REPO_DIR" reset --hard --quiet "$target"
  log "applying $(git -C "$REPO_DIR" log -1 --format='%h %s' "$target")"
  bash "$REPO_DIR/setup-telemt-web-node.sh"
  printf '%s\n' "$target" > "$STATE_FILE"
  log "deployed $target"
}

# ---- --set: change a node parameter without hand-editing files ----------------
# deploy.env is the node's parameters, not generated config, so changing it is
# legitimate — but a sed that silently matches nothing is how ME mode appeared
# to be enabled while telemt kept using Direct DC.
set_params(){
  [ -f "$ENV_FILE" ] || die "$ENV_FILE is missing — run setup-telemt-web-node.sh once first"
  local pair key value old
  for pair in "$@"; do
    case "$pair" in
      *=*) key="${pair%%=*}"; value="${pair#*=}" ;;
      *) die "expected KEY=VALUE, got: $pair" ;;
    esac
    if grep -q "^$key=" "$ENV_FILE"; then
      old="$(sed -n "s|^$key=||p" "$ENV_FILE" | head -1)"
      sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
      log "$key: '${old}' -> '$value'"
    else
      printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
      log "$key: (unset) -> '$value'"
    fi
  done
}

case "${1:-}" in
  --install) install_timer; exit 0 ;;
  --set)
    shift
    [ $# -gt 0 ] || die "--set needs at least one KEY=VALUE"
    set_params "$@"
    # Apply right away: a parameter that is stored but not applied is a lie.
    fetch_origin || log "WARNING: fetch failed, applying the current checkout"
    TARGET="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH" 2>/dev/null || git -C "$REPO_DIR" rev-parse HEAD)"
    apply "$TARGET"
    exit 0 ;;
  --status)
    fetch_origin || log "WARNING: fetch failed, comparing against the last known origin"
    TARGET="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
    echo "branch:   $BRANCH"
    echo "deployed: $(cat "$STATE_FILE" 2>/dev/null || echo '(never)')"
    echo "origin:   $TARGET  $(git -C "$REPO_DIR" log -1 --format='%s' "$TARGET")"
    systemctl --no-pager list-timers telemt-deploy.timer 2>/dev/null | head -3
    exit 0 ;;
  --force|"") ;;
  *) die "unknown argument: $1 (use --install, --set K=V, --force, --status, or none)" ;;
esac

[ -f "$ENV_FILE" ] || die "$ENV_FILE is missing — run setup-telemt-web-node.sh once first"

# One deploy at a time: the timer must not overlap a slow apply.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another deploy is running, skipping"; exit 0; }

fetch_origin || die "could not fetch origin/$BRANCH"
TARGET="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
CURRENT="$(cat "$STATE_FILE" 2>/dev/null || echo '')"

if [ "$TARGET" = "$CURRENT" ] && [ "${1:-}" != "--force" ]; then
  # Nothing new. Stay quiet so the timer doesn't fill the journal.
  exit 0
fi
apply "$TARGET"
