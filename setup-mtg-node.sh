#!/usr/bin/env bash
# =============================================================================
# setup-mtg-node.sh — reproducible MTProto proxy node on a clean VPS.
#
# Stands up 9seconds/mtg (fake-TLS, JA3S-clean since v2.2.8, April-2026 TSPU fix)
# in Docker, plus a lean, DPI-aware hardening baseline. Pure MTProto node —
# no tunnels, no extra proxies, nothing host-specific.
#
# Usage:
#   sudo DOMAIN=avito.ru PORT=8443 bash setup-mtg-node.sh
#   sudo DOMAIN=ya.ru PORT=443 SSH_HARDEN=1 bash setup-mtg-node.sh
#
# Idempotent: safe to re-run. Re-running keeps the existing secret unless you
# pass NEW_SECRET=1.
# =============================================================================
set -euo pipefail

# ---- config (override via env) ----------------------------------------------
DOMAIN="${DOMAIN:-avito.ru}"          # fronting SNI — MUST support TLS 1.3 *and* 1.2 (see notes)
PORT="${PORT:-8443}"                  # 443 blends best with HTTPS; 8443 keeps 443 free for other TLS
# Pin mtg by digest for reproducibility (June-2026 build d095108, go1.26.4).
# Update deliberately; `docker inspect nineseconds/mtg:latest --format '{{index .RepoDigests 0}}'`.
MTG_IMAGE="${MTG_IMAGE:-nineseconds/mtg@sha256:c42c19337fc47d171626e26f56a6549c6dc4e6cfaf0c47cc8900e18171b43555}"
CONTAINER="${CONTAINER:-mtproto-proxy}"
DOH_IP="${DOH_IP:-1.1.1.1}"
IP_PREF="${IP_PREF:-prefer-ipv4}"     # prefer-ipv4 / prefer-ipv6
SSH_HARDEN="${SSH_HARDEN:-0}"         # 1 = disable password login (needs a working SSH key first!)
NEW_SECRET="${NEW_SECRET:-0}"
STATE=/var/lib/mtg-node

log(){ printf '\n\033[1;36m### %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
mkdir -p "$STATE"

# ---- docker -----------------------------------------------------------------
log "Docker"
if ! command -v docker >/dev/null; then
  apt-get update -qq && apt-get install -y -qq docker.io
fi
systemctl enable --now docker >/dev/null 2>&1 || true
# log rotation + survive daemon restarts
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "5" }, "live-restore": true }
EOF
systemctl restart docker; sleep 2

# ---- secret + container -----------------------------------------------------
log "mtg proxy (fronting domain: $DOMAIN, port: $PORT)"
docker pull -q "$MTG_IMAGE" >/dev/null
if [ -f "$STATE/secret" ] && [ "$NEW_SECRET" = 0 ]; then
  SECRET="$(cat "$STATE/secret")"
else
  SECRET="$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$DOMAIN")"
  echo "$SECRET" > "$STATE/secret"; chmod 600 "$STATE/secret"
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --restart unless-stopped -p "$PORT:$PORT" \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop=ALL --security-opt no-new-privileges:true \
  --memory=256m --pids-limit=256 \
  "$MTG_IMAGE" simple-run -n "$DOH_IP" -i "$IP_PREF" "0.0.0.0:$PORT" "$SECRET" >/dev/null
sleep 4
docker inspect -f 'mtg: {{.State.Status}} restarts={{.RestartCount}}' "$CONTAINER"

# ---- swap (OOM guard on 1GB boxes) ------------------------------------------
log "swap"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
  grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  grep -q vm.swappiness /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
  sysctl -w vm.swappiness=10 >/dev/null
fi

# ---- firewall ---------------------------------------------------------------
log "ufw (allow SSH + proxy only)"
apt-get install -y -qq ufw >/dev/null
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"; SSH_PORT="${SSH_PORT:-22}"
ufw allow "$SSH_PORT/tcp" >/dev/null
ufw allow "$PORT/tcp" >/dev/null
ufw --force enable >/dev/null

# ---- fail2ban (SSH only) ----------------------------------------------------
log "fail2ban"
apt-get install -y -qq fail2ban >/dev/null
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 1d
findtime = 10m
maxretry = 3
[sshd]
enabled = true
backend = systemd
[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
EOF
systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban

# ---- scanner blocklist (SSH surface only — NEVER the proxy port) ------------
# Lesson learned: an abuse-IP blocklist on the proxy port drops legitimate
# users behind VPN / shared / CGNAT IPs. The proxy itself is protected by
# fake-TLS + domain fronting, so the blocklist guards only host services (SSH).
log "ipsum blocklist (INPUT/SSH only)"
apt-get install -y -qq ipset curl >/dev/null
cat > /usr/local/sbin/update-blocklist.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ipset create ipsum hash:net -exist
tmp=$(mktemp)
if curl -s --max-time 30 https://raw.githubusercontent.com/stamparm/ipsum/master/levels/4.txt -o "$tmp" && [ -s "$tmp" ]; then
  ipset create ipsum_new hash:net -exist; ipset flush ipsum_new
  grep -E '^[0-9]' "$tmp" | while read -r ip _; do ipset add ipsum_new "$ip" -exist; done
  ipset swap ipsum_new ipsum && ipset destroy ipsum_new
fi
rm -f "$tmp"
iptables -C INPUT -m set --match-set ipsum src -j DROP 2>/dev/null || iptables -I INPUT -m set --match-set ipsum src -j DROP
EOF
chmod +x /usr/local/sbin/update-blocklist.sh
cat > /etc/systemd/system/blocklist.service <<'EOF'
[Unit]
Description=Refresh ipsum blocklist (SSH surface)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-blocklist.sh
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/blocklist.timer <<'EOF'
[Unit]
Description=Daily blocklist refresh
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable blocklist.service blocklist.timer >/dev/null 2>&1
systemctl start blocklist.service || true
systemctl start blocklist.timer

# ---- trim useless-on-VPS services -------------------------------------------
log "trim (fwupd / multipathd)"
systemctl mask --now fwupd.service fwupd-refresh.service fwupd-refresh.timer >/dev/null 2>&1 || true
[ "$(multipath -ll 2>/dev/null | grep -c dm-)" = 0 ] && systemctl disable --now multipathd multipathd.socket >/dev/null 2>&1 || true
apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true; apt-get clean

# ---- optional SSH hardening (gated) -----------------------------------------
if [ "$SSH_HARDEN" = 1 ]; then
  log "SSH hardening (password login OFF)"
  if [ ! -s "$HOME/.ssh/authorized_keys" ] && [ ! -s /root/.ssh/authorized_keys ]; then
    echo "!! no authorized_keys found — refusing to disable password login (lockout risk)"
  else
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    sed -i -E \
      -e 's/^\s*#?\s*PasswordAuthentication.*/PasswordAuthentication no/I' \
      -e 's/^\s*#?\s*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/I' \
      -e 's/^\s*#?\s*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/I' \
      -e 's/^\s*#?\s*PermitRootLogin.*/PermitRootLogin prohibit-password/I' \
      /etc/ssh/sshd_config
    grep -qiE '^KbdInteractiveAuthentication' /etc/ssh/sshd_config || echo 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config
    sshd -t && systemctl reload ssh && echo "password login disabled (key-only)"
  fi
fi

# ---- summary ----------------------------------------------------------------
IP="$(curl -s --max-time 8 https://api.ipify.org || echo YOUR_IP)"
log "DONE"
echo "Proxy link (share this):"
echo "  https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
echo
echo "Notes:"
echo "  * Fronting domain $DOMAIN must support TLS 1.3 (client masquerade) AND 1.2"
echo "    (server-side fronting fallback; some hosts block outbound TLS 1.3)."
echo "  * July-2026 TSPU detects fake-TLS by client JA3/JA4 — tell users to UPDATE"
echo "    their Telegram app (carries the fixed ClientHello). Server side is on mtg"
echo "    $(docker run --rm "$MTG_IMAGE" --version 2>/dev/null | awk '{print $1}')."
echo "  * Secret stored at $STATE/secret. Re-run with NEW_SECRET=1 to rotate."
