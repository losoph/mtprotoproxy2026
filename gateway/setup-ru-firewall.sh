#!/usr/bin/env bash
# Run on the RU VDS to restrict proxy port access to the NL gateway only.
# Usage: sudo bash setup-ru-firewall.sh <NL_GATEWAY_IP>
set -euo pipefail

NL_IP="${1:?Usage: $0 <NL_GATEWAY_IP>}"
PROXY_PORT=8443
METRICS_PORT=9090

echo "Configuring ufw: allow proxy port $PROXY_PORT only from $NL_IP"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — keep open (adjust port if non-standard)
ufw allow 22/tcp

# Proxy port: only from the NL gateway
ufw allow from "$NL_IP" to any port "$PROXY_PORT" proto tcp

# Metrics: loopback only (Prometheus scrapes via SSH tunnel or VPN)
ufw allow from 127.0.0.1 to any port "$METRICS_PORT" proto tcp

ufw --force enable
ufw status verbose
