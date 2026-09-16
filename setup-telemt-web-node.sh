#!/usr/bin/env bash
# =============================================================================
# setup-telemt-web-node.sh — WEB proxy (tg://webproxy) node using telemt
#
# The WEB proxy type (Telegram's own PoC: telegramdesktop/tproxy-server) carries
# ordinary MTProxy streams inside plain HTTPS / WebSocket on port 443, so on the
# wire it looks like a normal website, not like fake-TLS MTProto. telemt >= 3.5.6
# implements it (`transport = "web"`), and — unlike tproxy-server, which wants
# Caddy to own 80/443 — telemt does NOT terminate TLS: an existing nginx keeps
# port 443 and reverse-proxies one dedicated vhost to telemt on loopback.
# That's what makes it deployable on a box that already serves a website (tldw).
#
# This script:
#   * installs/updates the telemt binary (pinned, checksum-verified),
#   * writes /etc/telemt/config.toml with BOTH transports — the existing
#     fake-TLS MTProto listener (kept, secret reused) and the new WEB listener,
#   * writes an nginx vhost for WEB_HOST and obtains a Let's Encrypt cert,
#   * verifies that the running binary actually has WEB support,
#   * prints the tg://webproxy link.
#
# Usage (on the box that already runs the website, e.g. tldw):
#   sudo WEB_HOST=cdn.example.com DECOY_UPSTREAM=http://127.0.0.1:8080 \
#        EMAIL=admin@example.com bash setup-telemt-web-node.sh
#
# Idempotent: safe to re-run. Secrets are kept unless NEW_SECRET=1.
# =============================================================================
set -euo pipefail

# ---- config (override via env) ----------------------------------------------
WEB_HOST="${WEB_HOST:-}"              # dedicated FQDN for the WEB proxy; must
                                      # resolve to this box (A/AAAA) and must NOT
                                      # be the hostname of the existing site —
                                      # the *whole* vhost goes to telemt.
PUBLIC_IP="${PUBLIC_IP:-}"            # public IPv4 of WEB_HOST; autodetected.
DECOY_UPSTREAM="${DECOY_UPSTREAM:-}"  # e.g. http://127.0.0.1:8080 — a private/
                                      # loopback origin of the site shown to
                                      # anyone who is not a proxy client.
                                      # Empty => a static placeholder snapshot.
SITE_HOST="${SITE_HOST:-}"            # optional: hostname of the site this box
                                      # already serves (e.g. tldw.orangerd.ru).
                                      # Given with SITE_UPSTREAM, nginx also
                                      # terminates TLS for it — handy when the
                                      # app used to sit on port 80 with no HTTPS.
SITE_UPSTREAM="${SITE_UPSTREAM:-}"    # its local origin, e.g. http://127.0.0.1:8080
SITE_MAX_BODY="${SITE_MAX_BODY:-512m}"  # nginx defaults to 1m, which silently breaks
                                        # an app that accepts uploads (audio, video,
                                        # images). 0 disables the limit entirely.
SITE_TIMEOUT="${SITE_TIMEOUT:-300s}"    # slow requests (transcoding, transcription)
                                        # must not be cut at nginx's 60s default
WEB_USERNAME="${WEB_USERNAME:-webproxy}"
WEB_LISTEN_PORT="${WEB_LISTEN_PORT:-18080}"   # private plain-HTTP listener
WEB_CARRIER="${WEB_CARRIER:-https}"           # final fallback; iOS supports only this
WEB_CARRIERS="${WEB_CARRIERS:-websocket-lanes,websocket,https-lanes}"  # negotiated, in order
SECRET_MODE="${SECRET_MODE:-dd}"              # dd | plain  (ee/fake-TLS is not
                                              # supported by WEB mode)

# --- the fake-TLS MTProto side stays as it was (setup-telemt-node.sh) --------
KEEP_MTPROTO="${KEEP_MTPROTO:-1}"     # 0 = WEB-only node
DOMAIN="${DOMAIN:-vkvideo.ru}"
PORT="${PORT:-443}"                   # fake-TLS port; 443 is taken by nginx on a
                                      # web box, so default to 8443 there (below)
USERNAME="${USERNAME:-proxy}"
CLIENT_MSS="${CLIENT_MSS:-tspu}"
CLIENT_MSS_BULK="${CLIENT_MSS_BULK:-1400}"

UPSTREAM_PROBE="${UPSTREAM_PROBE:-1}"   # continuous probe of the node's path to
                                        # the Telegram DCs; 0 removes it. It logs
                                        # only bad cycles, so the journal stays quiet.

# WEB needs the fixes/lifecycle controls of the 3.5.6+ line.
TELEMT_VERSION="${TELEMT_VERSION:-3.5.7}"
NEW_SECRET="${NEW_SECRET:-0}"
EMAIL="${EMAIL:-}"                    # for Let's Encrypt registration
CERTBOT="${CERTBOT:-1}"               # 0 = certificate is managed elsewhere
STATE=/var/lib/telemt
BIN=/usr/local/bin/telemt

log(){ printf '\n\033[1;36m### %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -n "$WEB_HOST" ] || die "WEB_HOST is required (dedicated FQDN pointing at this box)"
case "$SECRET_MODE" in dd|plain) ;; *) die "SECRET_MODE must be dd or plain (ee is not supported by WEB mode)";; esac

# nginx owns 443 on a web box; don't let the fake-TLS listener collide with it.
if [ "$KEEP_MTPROTO" = 1 ] && [ "$PORT" = 443 ]; then
  PORT=8443
  log "port 443 is nginx's on this box — fake-TLS MTProto moved to $PORT (override with PORT=)"
elif [ "$KEEP_MTPROTO" = 0 ] && [ "$PORT" = 443 ]; then
  # WEB-only: no MTProxy listener is written, but keep server.port off 443 so a
  # default bind can never race nginx for the WEB endpoint's own port.
  PORT=18443
fi

# ---- preflight: ports 80/443 must be ours ------------------------------------
# nginx has to own both (80 for ACME + redirect, 443 for the WEB endpoint —
# Telegram Desktop requires port 443). telemt on 443 is fine: it is moved to
# $PORT further down. Anything else has to be relocated first, so say so now
# instead of failing halfway through an nginx install.
port_holder(){
  command -v ss >/dev/null || return 0   # no ss: skip the check, nginx will complain
  ss -ltnpH "sport = :$1" 2>/dev/null | sed -n '1s/.*users:(("\([^"]*\)".*/\1/p'
}
H80="$(port_holder 80)"
case "$H80" in
  ""|nginx) ;;
  *) die "port 80 is held by '$H80' — nginx needs it (ACME + redirect).
    If that is a Docker container, republish it on loopback instead, e.g.
    -p 127.0.0.1:8080:80 (or ports: 127.0.0.1:8080:80 in compose), then pass
    SITE_HOST=<its hostname> SITE_UPSTREAM=http://127.0.0.1:8080 so nginx
    serves it over HTTPS as well." ;;
esac
H443="$(port_holder 443)"
case "$H443" in
  ""|nginx|telemt) ;;
  *) die "port 443 is held by '$H443' — the WEB endpoint must be on 443. Move that service first." ;;
esac
if [ -n "$SITE_HOST" ] && [ -z "$SITE_UPSTREAM" ]; then
  die "SITE_HOST needs SITE_UPSTREAM (the site's local origin, e.g. http://127.0.0.1:8080)"
fi

mkdir -p "$STATE" /etc/telemt "$STATE/tlsfront"

# ---- arch detection ----------------------------------------------------------
case "$(uname -m)" in
  x86_64)  ASSET="telemt-x86_64-linux-gnu.tar.gz" ;;
  aarch64) ASSET="telemt-aarch64-linux-gnu.tar.gz" ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

# ---- download + verify -------------------------------------------------------
log "telemt binary ($TELEMT_VERSION, $ASSET)"
BASE_URL="https://github.com/telemt/telemt/releases/download/$TELEMT_VERSION"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$BASE_URL/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE_URL/$ASSET.sha256" -o "$TMP/$ASSET.sha256"
(cd "$TMP" && sha256sum -c "$ASSET.sha256")
tar -xzf "$TMP/$ASSET" -C "$TMP"
install -m 755 "$TMP/telemt" "$BIN"
"$BIN" --version

# ---- public IP ----------------------------------------------------------------
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -fsS --max-time 8 https://api.ipify.org || true)"
  [ -n "$PUBLIC_IP" ] || die "could not autodetect the public IP — pass PUBLIC_IP=..."
fi
RESOLVED="$(getent ahostsv4 "$WEB_HOST" | awk 'NR==1{print $1}' || true)"
if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
  log "WARNING: $WEB_HOST resolves to $RESOLVED but this box looks like $PUBLIC_IP."
  log "         public_addr must be the address clients actually reach (see docs)."
fi

# ---- secrets ------------------------------------------------------------------
gen_secret(){ openssl rand -hex 16; }
if [ -f "$STATE/secret" ] && [ "$NEW_SECRET" = 0 ]; then
  SECRET="$(cat "$STATE/secret")"
else
  SECRET="$(gen_secret)"; echo "$SECRET" > "$STATE/secret"; chmod 600 "$STATE/secret"
fi
if [ -f "$STATE/web-secret" ] && [ "$NEW_SECRET" = 0 ]; then
  WEB_SECRET="$(cat "$STATE/web-secret")"
else
  WEB_SECRET="$(gen_secret)"; echo "$WEB_SECRET" > "$STATE/web-secret"; chmod 600 "$STATE/web-secret"
fi
# API control token — /v1/runtime/web/* is how you inspect and drain WEB sessions.
if [ -f "$STATE/api-token" ] && [ "$NEW_SECRET" = 0 ]; then
  API_TOKEN="$(cat "$STATE/api-token")"
else
  API_TOKEN="$(openssl rand -hex 24)"; echo "$API_TOKEN" > "$STATE/api-token"; chmod 600 "$STATE/api-token"
fi

# ---- decoy --------------------------------------------------------------------
# Everything that is not an authenticated carrier request — a scanner, a curious
# ISP, a browser — must get an ordinary site back. That is the anti-probing
# contract, not decoration.
if [ -n "$DECOY_UPSTREAM" ]; then
  case "$DECOY_UPSTREAM" in
    http://127.*|http://10.*|http://192.168.*|http://169.254.*) ;;
    http://172.1[6-9].*|http://172.2[0-9].*|http://172.3[01].*) ;;
    *) die "DECOY_UPSTREAM must be an http:// origin on a loopback/private IP literal (telemt rejects public or named origins)";;
  esac
  DECOY_TOML="mode = \"http_upstream\"
upstream = \"$DECOY_UPSTREAM\""
else
  mkdir -p "$STATE/public"
  if [ ! -f "$STATE/public/index.html" ]; then
    cat > "$STATE/public/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Static assets</title>
<style>body{font:16px/1.5 system-ui,sans-serif;margin:8% auto;max-width:34em;padding:0 1em;color:#222}</style>
<h1>Static assets</h1>
<p>This host serves static files for internal applications. There is no
public index; request a file by its path.</p>
HTML
  fi
  DECOY_TOML="mode = \"static_directory\"
directory = \"$STATE/public\"
index = \"index.html\""
  log "no DECOY_UPSTREAM given — using a static placeholder in $STATE/public."
  log "On a box that already runs a site, point DECOY_UPSTREAM at its local origin instead."
fi

# ---- config -------------------------------------------------------------------
log "config (web host: $WEB_HOST, carrier: $WEB_CARRIER, mtproto: $([ "$KEEP_MTPROTO" = 1 ] && echo "$DOMAIN:$PORT" || echo off))"
{
cat <<EOF
### telemt — generated by setup-telemt-web-node.sh, $(date -u +%F)
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = $PORT
EOF

if [ "$KEEP_MTPROTO" = 1 ] && [ -n "$CLIENT_MSS" ]; then
  echo "client_mss = \"$CLIENT_MSS\""
  [ -n "$CLIENT_MSS_BULK" ] && echo "client_mss_bulk = \"$CLIENT_MSS_BULK\""
fi

cat <<EOF

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
auth_header = "Bearer $API_TOKEN"
read_only = false
EOF

if [ "$KEEP_MTPROTO" = 1 ]; then
cat <<EOF

# --- fake-TLS MTProto (unchanged behaviour of setup-telemt-node.sh) ---
[[server.listeners]]
ip = "0.0.0.0"
EOF
fi

cat <<EOF

# --- WEB transport: plain HTTP/1.1 from nginx only, never exposed directly ---
[[server.listeners]]
ip = "127.0.0.1"
port = $WEB_LISTEN_PORT
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "$WEB_CARRIER"
$([ -n "$WEB_CARRIERS" ] && printf 'carriers = [%s]' "$(printf '"%s", ' ${WEB_CARRIERS//,/ } | sed 's/, $//')")
carrier_learning = true
http_connection_capacity_action = "respond"

[[web.vhosts]]
host = "$WEB_HOST"
public_addr = "$PUBLIC_IP:443"

[web.vhosts.decoy]
$DECOY_TOML

[[web.vhosts.profiles]]
user = "$WEB_USERNAME"
secret_mode = "$SECRET_MODE"

[censorship]
tls_domain = "$DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "$STATE/tlsfront"

[access.users]
$WEB_USERNAME = "$WEB_SECRET"
EOF

[ "$KEEP_MTPROTO" = 1 ] && echo "$USERNAME = \"$SECRET\""
} > /etc/telemt/config.toml
chmod 600 /etc/telemt/config.toml

# ---- systemd -------------------------------------------------------------------
log "systemd unit"
cat > /etc/systemd/system/telemt.service <<'EOF'
[Unit]
Description=telemt - MTProto proxy for Telegram (fake-TLS + WEB)
Documentation=https://github.com/telemt/telemt/blob/main/docs/WEB/WEB_PROXY.en.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/config.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/telemt

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable telemt >/dev/null
systemctl restart telemt
sleep 2
systemctl is-active --quiet telemt || { journalctl -u telemt -n 30 --no-pager; die "telemt failed to start"; }

# ---- verify the binary really has WEB --------------------------------------------
# Release notes are not a guarantee: ask the running process.
log "WEB runtime check"
if ! curl -fsS --max-time 5 -H "Authorization: Bearer $API_TOKEN" \
      http://127.0.0.1:9091/v1/runtime/web/status >/dev/null; then
  journalctl -u telemt -n 30 --no-pager
  die "this telemt build has no /v1/runtime/web/status — WEB support is missing; pin a newer TELEMT_VERSION"
fi

# ---- upstream probe ----------------------------------------------------------------
# Episodic upstream failures (telemt: "Connection timeout to <DC>:443", then
# "No healthy upstreams available") look like a broken proxy to users while every
# manual check passes. Keep a continuous record so the cause is decidable later.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$UPSTREAM_PROBE" = 1 ] && [ -f "$SELF_DIR/tools/upstream-probe.sh" ]; then
  log "upstream probe"
  cat > /etc/systemd/system/telemt-upstream-probe.service <<EOF
[Unit]
Description=Probe the node's path to the Telegram DCs (records episodic loss)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $SELF_DIR/tools/upstream-probe.sh
Restart=always
RestartSec=10
Nice=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable telemt-upstream-probe.service >/dev/null
  systemctl restart telemt-upstream-probe.service
elif [ -f /etc/systemd/system/telemt-upstream-probe.service ]; then
  log "removing upstream probe (UPSTREAM_PROBE=$UPSTREAM_PROBE)"
  systemctl disable --now telemt-upstream-probe.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/telemt-upstream-probe.service
  systemctl daemon-reload
fi

# ---- nginx ------------------------------------------------------------------------
if ! command -v nginx >/dev/null; then
  log "installing nginx (WEB mode needs an external TLS terminator)"
  apt-get update -qq && apt-get install -y -qq nginx
fi
log "nginx vhost for $WEB_HOST${SITE_HOST:+ (+ site $SITE_HOST)}"
NG_AVAIL=/etc/nginx/sites-available; NG_EN=/etc/nginx/sites-enabled
[ -d "$NG_AVAIL" ] || { NG_AVAIL=/etc/nginx/conf.d; NG_EN=/etc/nginx/conf.d; }
CERT_DIR="/etc/letsencrypt/live/$WEB_HOST"

write_http_only(){
  cat > "$NG_AVAIL/telemt-web.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $WEB_HOST${SITE_HOST:+ $SITE_HOST};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
}

# nginx >= 1.25.1 wants `http2 on;`, older releases the `listen ... http2` flag.
nginx_http2_lines(){
  local v; v="$(nginx -v 2>&1 | sed 's#.*/##')"
  if [ "$(printf '%s\n1.25.1\n' "$v" | sort -V | head -1)" = "1.25.1" ]; then
    printf '    listen 443 ssl;\n    listen [::]:443 ssl;\n    http2 on;\n'
  else
    printf '    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n'
  fi
}

write_tls(){
  cat > "$NG_AVAIL/telemt-web.conf" <<EOF
# Generated by setup-telemt-web-node.sh — WEB proxy vhost for $WEB_HOST.
# The COMPLETE vhost is forwarded to telemt: splitting carrier paths here would
# make ordinary and authenticated traffic observably different and would bypass
# telemt's decoy policy.
map \$http_upgrade \$telemt_connection_upgrade {
    default upgrade;
    ''      '';
}

upstream telemt_web {
    server 127.0.0.1:$WEB_LISTEN_PORT;
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    # Both names, or the site's plain-HTTP visitors land on nginx's default vhost
    # instead of a redirect — and its ACME renewal stops being served from here.
    server_name $WEB_HOST${SITE_HOST:+ $SITE_HOST};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
$(nginx_http2_lines)
    server_name $WEB_HOST;

    # Raw queries carry bridge capabilities and Authorization carries bearer
    # credentials — never log them.
    access_log off;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    client_max_body_size 2m;   # >= web.limits.max_body_bytes

    location / {
        proxy_pass http://telemt_web;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;   # overwrite, don't append
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_connection_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;    # > long_poll_secs (25) and 2x ws liveness
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;   # the bridge does its own byte-identical retries
    }
}
EOF
  # The ordinary site keeps its own hostname and its own vhost: the proxy vhost
  # must stay a plain website to anyone who is not a carrier client.
  if [ -n "$SITE_HOST" ]; then
    cat >> "$NG_AVAIL/telemt-web.conf" <<EOF

server {
$(nginx_http2_lines)
    server_name $SITE_HOST;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    client_max_body_size $SITE_MAX_BODY;

    location / {
        proxy_pass $SITE_UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_connection_upgrade;

        proxy_read_timeout $SITE_TIMEOUT;
        proxy_send_timeout $SITE_TIMEOUT;
        proxy_request_buffering off;   # stream uploads through instead of
                                       # spooling the whole body to disk first
    }
}
EOF
  fi
}

if [ "$NG_EN" != "$NG_AVAIL" ]; then
  ln -sf "$NG_AVAIL/telemt-web.conf" "$NG_EN/telemt-web.conf"
fi

if [ ! -s "$CERT_DIR/fullchain.pem" ] && [ "$CERTBOT" = 1 ]; then
  log "certificate for $WEB_HOST (Let's Encrypt, webroot)"
  command -v certbot >/dev/null || { apt-get update -qq && apt-get install -y -qq certbot; }
  mkdir -p /var/www/html
  write_http_only
  nginx -t && systemctl reload nginx
  CB_DOMAINS=(-d "$WEB_HOST")
  [ -n "$SITE_HOST" ] && CB_DOMAINS+=(--cert-name "$WEB_HOST" -d "$SITE_HOST")
  if [ -n "$EMAIL" ]; then
    certbot certonly --webroot -w /var/www/html "${CB_DOMAINS[@]}" -m "$EMAIL" --agree-tos -n
  else
    certbot certonly --webroot -w /var/www/html "${CB_DOMAINS[@]}" --register-unsafely-without-email --agree-tos -n
  fi
fi
[ -s "$CERT_DIR/fullchain.pem" ] || die "no certificate at $CERT_DIR — obtain one, then re-run (or set CERTBOT=0 and edit the vhost)"

# A renewed certificate is only served once nginx re-reads it, and `certbot
# certonly` reloads nothing by itself — so a silent expiry in 90 days would take
# the proxy down with the site. One deploy hook covers every cert on the box.
if [ -d /etc/letsencrypt ]; then
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi

write_tls
nginx -t || die "nginx config test failed"
systemctl reload nginx

# ---- firewall -----------------------------------------------------------------
if command -v ufw >/dev/null; then
  log "ufw"
  ufw allow 80/tcp  >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  [ "$KEEP_MTPROTO" = 1 ] && { ufw allow "$PORT/tcp" >/dev/null || true; }
  # The plain WEB listener is loopback-only; deny it explicitly anyway.
  ufw deny "$WEB_LISTEN_PORT/tcp" >/dev/null || true
fi

# ---- smoke test ------------------------------------------------------------------
log "decoy check through the public endpoint"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$WEB_HOST/" || echo 000)"
echo "  GET https://$WEB_HOST/            -> $CODE"
CODE404="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$WEB_HOST/no-such-path" || echo 000)"
echo "  GET https://$WEB_HOST/no-such-path -> $CODE404 (must look like an ordinary site, not an error page from telemt)"

# ---- record this invocation for deploy.sh ------------------------------------------
# A deploy replays exactly these values against a newer checkout, so the node's
# configuration follows git instead of hand edits. NEW_SECRET is deliberately not
# recorded: a deploy must never rotate secrets behind your back.
cat > /etc/telemt/deploy.env <<EOF
WEB_HOST=$WEB_HOST
PUBLIC_IP=$PUBLIC_IP
WEB_USERNAME=$WEB_USERNAME
WEB_LISTEN_PORT=$WEB_LISTEN_PORT
WEB_CARRIER=$WEB_CARRIER
WEB_CARRIERS=$WEB_CARRIERS
SECRET_MODE=$SECRET_MODE
SITE_HOST=$SITE_HOST
SITE_UPSTREAM=$SITE_UPSTREAM
SITE_MAX_BODY=$SITE_MAX_BODY
SITE_TIMEOUT=$SITE_TIMEOUT
DECOY_UPSTREAM=$DECOY_UPSTREAM
KEEP_MTPROTO=$KEEP_MTPROTO
DOMAIN=$DOMAIN
PORT=$PORT
USERNAME=$USERNAME
CLIENT_MSS=$CLIENT_MSS
CLIENT_MSS_BULK=$CLIENT_MSS_BULK
TELEMT_VERSION=$TELEMT_VERSION
UPSTREAM_PROBE=$UPSTREAM_PROBE
EMAIL=$EMAIL
CERTBOT=$CERTBOT
EOF
chmod 600 /etc/telemt/deploy.env

# ---- summary -----------------------------------------------------------------------
if [ "$SECRET_MODE" = dd ]; then LINK_SECRET="dd$WEB_SECRET"; else LINK_SECRET="$WEB_SECRET"; fi
log "DONE"
echo "WEB proxy (Telegram Desktop builds with the WEB proxy type; no port — 443 is implied):"
echo "  tg://webproxy?server=$WEB_HOST&secret=$LINK_SECRET"
echo "  https://t.me/webproxy?server=$WEB_HOST&secret=$LINK_SECRET"
if [ "$KEEP_MTPROTO" = 1 ]; then
  echo
  echo "fake-TLS MTProto (unchanged, all clients):"
  echo "  https://t.me/proxy?server=$PUBLIC_IP&port=$PORT&secret=ee${SECRET}$(printf '%s' "$DOMAIN" | od -An -tx1 | tr -d ' \n')"
fi
cat <<EOF

Notes:
  * Secrets: $STATE/web-secret (WEB), $STATE/secret (fake-TLS), $STATE/api-token (control API).
    Re-run with NEW_SECRET=1 to rotate all three.
  * Inspect WEB sessions:
      curl -sS -H "Authorization: Bearer \$(cat $STATE/api-token)" \\
        http://127.0.0.1:9091/v1/runtime/web/status | head -40
  * Turn on the debug view by adding [web.debug] enabled = true and reloading, then
    open http://127.0.0.1:9091/web-status through an SSH tunnel.
  * $WEB_HOST must serve ONLY this proxy vhost. Keep the real site on its own
    hostname; the decoy is what casual visitors of $WEB_HOST see.${SITE_HOST:+
  * $SITE_HOST is served over HTTPS from $SITE_UPSTREAM by the same nginx.}
  * Upstream path to the Telegram DCs is probed continuously; only bad cycles
    are logged: journalctl -u telemt-upstream-probe --since today
  * Configuration follows git: commit a change, push, and the node applies it
    (bash deploy.sh --install once, then journalctl -u telemt-deploy -f).
    Editing /etc/nginx or /etc/telemt by hand is overwritten by the next deploy.
  * Full upstream guide:
    https://github.com/telemt/telemt/blob/main/docs/WEB/WEB_PROXY.en.md
EOF
