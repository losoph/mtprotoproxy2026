# Node: tldw (`aiqu`, 45.145.64.58)

The production node as of 2026-09-16. It is not a dedicated proxy box: it also
serves a web application, which is exactly why the WEB proxy type fits here.

| | |
| --- | --- |
| Provider | Selectel (Russian network — see [`../upstream-path.md`](../upstream-path.md)) |
| OS | Ubuntu 24.04, kernel 6.8.0-139, 4 cores, 50 GB disk |
| Proxy | telemt 3.5.7, WEB transport only (`KEEP_MTPROTO=0`) |
| Proxy hostname | `cdn.orangerd.ru` |
| Site hostname | `tldw.orangerd.ru` (whisper-app, behind its own basic auth) |
| Deploy | `deploy.sh` timer on `main`, checkout in `/root/mtprotoproxy2026` |

## Who owns which port

```
0.0.0.0:80   nginx (host)      ACME + redirect to HTTPS for both hostnames
0.0.0.0:443  nginx (host)      TLS for both hostnames; one Let's Encrypt cert
127.0.0.1:18080  telemt        WEB listener, plain HTTP/1.1 from nginx only
127.0.0.1:9091   telemt        control API + /web-status (token in /var/lib/telemt/api-token)
127.0.0.1:8080   docker        whisper-app's own nginx -> whisper-app-web:8000
127.0.0.1:11434  docker        ollama
127.0.0.1:5432   postgres
0.0.0.0:2258     sshd
```

Port 80 used to be published by the `whisper-app-nginx-1` container as
`0.0.0.0:80->80/tcp`. It was moved to `127.0.0.1:8080:80` in
`/root/whisper-app/docker-compose.yml` (backup: `docker-compose.yml.bak`) so the
host nginx could own 80/443. That edit lives in the whisper-app repo, not here —
if that project is redeployed from its own source, the port mapping must survive.

All six containers (`whisper-app-{nginx,web,worker,ollama}`, `unagi-bot`,
`tndr-bot`) have `restart=unless-stopped`, so they return after a reboot.

## Decisions and why

- **telemt behind nginx, not Telegram's `tproxy-server`.** The official PoC wants
  Caddy to own 80/443, which collides with the existing site. telemt implements
  the same WEB protocol as `transport = "web"` and never terminates TLS.
- **A dedicated hostname, whole-vhost.** `cdn.orangerd.ru` goes entirely to
  telemt. Splitting only carrier paths at nginx would make authenticated and
  ordinary traffic observably different and bypass telemt's decoy policy.
- **Static decoy, not the application.** `DECOY_UPSTREAM` is deliberately unset:
  the app answers `401` with `WWW-Authenticate: Basic realm="TLDW"`, which is an
  odd thing for a host named `cdn` to do and ties the proxy hostname to the
  site's. The decoy is `/var/lib/telemt/public/index.html`, a plain static-asset
  page. Replace the file (any deploy keeps it) rather than pointing the decoy at
  an authenticated app.
- **fake-TLS is off on this node.** Consequence to keep in mind: **phones have no
  way in.** WEB exists in Telegram Desktop; iOS supports only the `https`
  carrier, Android is proof-of-concept. To bring fake-TLS back alongside WEB, set
  `KEEP_MTPROTO=1` and `PORT=8443` in `/etc/telemt/deploy.env` and run
  `deploy.sh --force`; the previous `tldw` user secret is in
  `/root/telemt-config.toml.bak`, and its links need the new port.
- **ME (middle-proxy) mode is off and must stay off here.** It was tried on
  2026-09-16 and cannot start: the proxy-secret fetch from `core.telegram.org`
  times out like everything else in Telegram's prefixes, and the retry loop
  degrades the direct path too. See [`../upstream-path.md`](../upstream-path.md).
- **Site limits.** `SITE_MAX_BODY=512m` and `SITE_TIMEOUT=300s` exist because
  nginx's 1 MiB body limit and 60 s proxy timeout would silently break the
  application's audio uploads.

## The tunnels (the thing that actually broke)

Telegram prefixes do not leave this node directly: they are routed into an
OpenVPN tunnel (`openvpn-client@tldw-main` / `tldw-media`, `tun10` / `tun11`),
Google prefixes into the other. Both terminate on the same `nl3.pvpn.pw` with the
same credential and the same client address, which made the server evict each
session in turn — 496 reconnects a day, and the Telegram routes bouncing between
the two devices. That, not censorship, was behind every symptom measured on
2026-09-16. Full account in [`../upstream-path.md`](../upstream-path.md).

Anything diagnosing this proxy has to check the egress path first:

```bash
ip route get 149.154.167.51                 # which device, right now
journalctl -u 'openvpn*' --since '24 hours ago' | grep -c 'Initialization Sequence Completed'
journalctl -u telemt-upstream-probe --since today | grep 'egress moved'
```

## Verified state

WEB works end to end: a Telegram Desktop client negotiated `websocket-lanes` on
the first attempt, reached `state: healthy`, and survived switching between a VPN
and a Russian location — the two switched-away sessions show as
`closed_before_health` (a neutral diagnostic outcome, not a failure), with zero
`reported_failures` on any carrier. nginx's timeouts (65 s) do not truncate the
25 s long poll.

**Not yet tested:** the whole point — a Russian mobile carrier (MegaFon/MTS)
without a VPN, session held for ten minutes.

## Secret hygiene on this node

The WEB link has been pasted in plain text into a chat transcript, and telemt
prints it to journald on every start (`[general.links] show = "*"`). Treat the
current secret as known outside the node. Rotate with:

```bash
set -a; . /etc/telemt/deploy.env; set +a
NEW_SECRET=1 bash /root/mtprotoproxy2026/setup-telemt-web-node.sh
```

That rotates the WEB secret, the fake-TLS secret and the API token, and prints
new links. Deploys never rotate anything.

## Traps this node taught us

- A unit with `ProtectHome=true` cannot see anything under `/root`, so scripts a
  service runs are installed into `/usr/local/bin`, never referenced inside the
  deploy checkout.
- telemt's control API opens only after STUN and the DC connectivity sweep —
  about 7 s normally, longer while the DC path flaps. Any readiness check must
  poll and distinguish "not listening yet" from a `404`.
- `certbot certonly` reloads nothing; the renewal deploy hook in
  `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` is what keeps the
  endpoint alive past day 90.
- The port-80 server block must name **both** hostnames, or plain-HTTP visitors
  to the site land on nginx's default vhost and the site's ACME challenge is only
  served by accident.
