# mtprotoproxy2026

Ready-to-deploy **MTProto proxy for a single VPS** — a curated, current
set of settings and bootstrap scripts, tuned for the 2026 Russian DPI
(TSPU) reality. Not a code fork: it packages a tested, maintained proxy
(fake-TLS) plus a lean hardening baseline that survives re-installs and
reboots.

> Scope: a clean MTProto node. No tunnels, no gateways, no host-specific glue.
> Bring it up on any fresh Ubuntu VPS in one command.

## Quick start (current: telemt)

**telemt** (Rust/Tokio, [telemt/telemt](https://github.com/telemt/telemt)) is
what actually runs in production now. It was deployed and tuned by hand on
the server first (see git history); `setup-telemt-node.sh` reproduces that
deployment from a GitHub release so the next box doesn't need manual setup.

```bash
# on a clean Ubuntu 22.04/24.04 VPS, as root:
sudo DOMAIN=vkvideo.ru PORT=443 USERNAME=proxy bash setup-telemt-node.sh
```

The script downloads a pinned, checksum-verified telemt release, writes
`/etc/telemt/config.toml` (fake-TLS + real front-cert emulation via
`tls_emulation`) and a hardened systemd unit (`CAP_NET_BIND_SERVICE` only,
`ProtectSystem=strict`), then enables the service. See
[`telemt/config.reference.toml`](telemt/config.reference.toml) for the full
annotated option list — e.g. multiple users, `use_middle_proxy`, metrics.
Re-runnable; pass `NEW_SECRET=1` to rotate the secret, `TELEMT_VERSION=x.y.z`
to pin a different release.

> Unlike `mtg` below, telemt's `tls_domain` is a plain config field, not
> embedded in the user secret — rotating the domain doesn't rotate secrets.

## WEB proxy (`tg://webproxy`) — for a box that already serves a website

Fake-TLS is the thing TSPU now fingerprints. Telegram's answer is a second
proxy type, **WEB** ([PoC: `telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server)):
the app keeps normal MTProxy framing and encryption but carries it inside
ordinary HTTPS / WebSocket requests to a real hostname on port 443. On the wire
it is a website, so there is no MTProto handshake to fingerprint — what is
exposed instead is the hostname and its behaviour under probing.

`tproxy-server` wants Caddy to own ports 80/443, which collides with an existing
web server. **telemt >= 3.5.6 implements the same protocol** as
`transport = "web"` and deliberately does *not* terminate TLS: the existing
nginx keeps 443 and reverse-proxies one dedicated vhost to telemt on loopback.
That is the variant this repo ships.

```bash
# on the box that already runs a site (e.g. tldw), as root:
sudo WEB_HOST=cdn.example.com \
     SITE_HOST=tldw.example.com SITE_UPSTREAM=http://127.0.0.1:8080 \
     DECOY_UPSTREAM=http://127.0.0.1:8080 \
     EMAIL=admin@example.com \
     bash setup-telemt-web-node.sh
```

nginx is installed if missing. Ports 80 and 443 must end up nginx's, and the
script refuses early (naming the holder) if they are not:

- **443 held by telemt** is expected — the fake-TLS listener is moved to 8443,
  which invalidates links that used port 443. Pass `PORT=` to choose another
  port, or `KEEP_MTPROTO=0` for a WEB-only node.
- **80 held by a Docker container** (a common shape: the app, or its own
  containerized nginx, published as `-p 80:80`) must be republished on loopback —
  `-p 127.0.0.1:8080:80` — and then passed as `SITE_HOST`/`SITE_UPSTREAM`, so the
  host nginx serves that site over HTTPS on its own hostname next to the proxy
  vhost. `SITE_MAX_BODY` (default 512m) and `SITE_TIMEOUT` (300s) exist because
  nginx's 1m body limit and 60s proxy timeout silently break an app that takes
  uploads or answers slowly.

### Deploys, not hand edits

`setup-telemt-web-node.sh` records its invocation in `/etc/telemt/deploy.env`,
and [`deploy.sh`](deploy.sh) replays it against a newer checkout:

```bash
sudo bash deploy.sh --install   # systemd timer, every 5 min (once)
sudo bash deploy.sh --status    # what is deployed vs. what origin has
sudo bash deploy.sh --force     # apply now, new commit or not
journalctl -u telemt-deploy -f
```

A deploy only runs when the branch head moved (the timer is otherwise silent),
takes one deploy at a time via flock, and never rotates secrets — `NEW_SECRET`
is not inherited. It does restart telemt and reload nginx, so live WEB sessions
reconnect.

Editing `/etc/nginx/*` or `/etc/telemt/*` on the node is not a shortcut: the
next deploy overwrites it, and in between the box is in a state no commit
describes. Fix it in the repo, push, deploy.

> Keeping fake-TLS on the public 443 via SNI routing (nginx `stream` +
> `ssl_preread`) looks tempting but breaks `client_mss`: the ServerHello
> fragmentation that gets past TSPU needs telemt's own socket to the client,
> not one to a local proxy.

The script installs telemt (pinned 3.5.7), writes a config with **both**
transports — the existing fake-TLS listener (secret reused, moved off 443 to
8443 since nginx has 443) and the new WEB listener on `127.0.0.1:18080` — adds
the nginx vhost, gets a Let's Encrypt certificate, verifies through the control
API that the binary really has WEB, and prints the link:

```text
https://t.me/webproxy?server=cdn.example.com&secret=dd<32 hex>
```

See [`telemt/config.web.reference.toml`](telemt/config.web.reference.toml) for
the annotated config and
[`telemt/nginx-telemt-web.conf.example`](telemt/nginx-telemt-web.conf.example)
for the vhost.

Rules that are easy to get wrong:

- **A dedicated hostname, not a path.** The *entire* vhost is forwarded to
  telemt. Splitting only the carrier paths at nginx would make authenticated and
  ordinary traffic observably different and would bypass telemt's decoy policy.
  Keep the real site on its own hostname.
- **The decoy is the anti-probing contract.** Everything that is not an
  authenticated carrier request must get a plausible site back — point
  `DECOY_UPSTREAM` at the local origin of a site you actually serve, and check
  `/` and a 404 through the public endpoint before handing the link out.
- **No `ee` secrets.** WEB uses `dd` or `plain` 16-byte secrets; the fake-TLS
  `ee` form is not accepted. It is a separate secret from the MTProto one.
- **Client support decides the carrier.** Desktop builds with the WEB proxy type
  negotiate WebSocket/lane carriers; current iOS speaks only plain `https`, so
  `carrier = "https"` stays the fallback. Android is still PoC-grade.
- **Timeouts.** nginx `proxy_read/send_timeout` must exceed the 25 s long poll
  (65 s in the shipped vhost), `proxy_buffering off`, `proxy_next_upstream off`,
  and `X-Forwarded-For` must be overwritten, not appended.
- **Don't log.** `access_log off` on that vhost: raw queries carry bridge
  capabilities, `Authorization` carries bearer credentials.

Running both types side by side is the sane test setup: the fake-TLS link keeps
working for clients that still get through, the WEB link is what you hand to
users whose carrier kills fake-TLS.

## Alternative: mtg (Docker)

An earlier setup based on [`9seconds/mtg`](https://github.com/9seconds/mtg) in
Docker. Still valid, no longer the default — kept as a documented fallback,
e.g. if you'd rather not run a bare binary as root, or want Docker isolation.

```bash
# on a clean Ubuntu 22.04/24.04 VPS, as root:
sudo DOMAIN=avito.ru PORT=8443 bash setup-mtg-node.sh
```

The script installs Docker + `mtg` (pinned by digest), generates a fake-TLS
secret for your fronting domain, and applies hardening (ufw, fail2ban, scanner
blocklist on SSH only, swap, service trim). It prints the `t.me/proxy?...` link
at the end. Re-runnable; pass `SSH_HARDEN=1` to also disable password login,
`NEW_SECRET=1` to rotate the secret.

## The 2026 TSPU reality (read this)

Since **1 April 2026** Russian DPI classifies MTProto fake-TLS as `TELEGRAM_TLS`
and blocks it by **JA3/JA4 fingerprint** of the client's TLS ClientHello,
sending forged RST. Two-sided fix:

- **Server:** `mtg` ≥ **2.2.8** cleaned the ServerHello fingerprint (JA3S ≈
  Chrome 132). This repo pins a post-fix build — nothing to do.
- **Client:** the fixed ClientHello ships in the **Telegram app update**
  (key_share 20→32 bytes, ext `0xfe02→0xfe0d`). **Tell your users to update
  Telegram** — the server fix alone is only half the job.

Public proxies now die in <48h. Private, low-volume nodes on current builds +
updated clients survive.

## Choosing the fronting domain (SNI)

Applies to both proxies — for `mtg` the domain is embedded in the secret
itself, for telemt it's the separate `tls_domain` config field (see note
above). Either way, the domain must:

1. **Support TLS 1.3** — so the fake-TLS (always 1.3-shaped) is consistent with
   the real domain. Verify from an unblocked host (system `openssl` can lie):
   ```python
   python3 - <<'PY'
   import ssl,socket
   c=ssl.create_default_context();c.check_hostname=False;c.verify_mode=ssl.CERT_NONE
   c.minimum_version=ssl.TLSVersion.TLSv1_3
   for h in ["avito.ru","ya.ru","vk.com","ozon.ru"]:
       try:
           with socket.create_connection((h,443),8) as s, c.wrap_socket(s,server_hostname=h) as ss: print(h,ss.version())
       except Exception as e: print(h,"NO 1.3",e)
   PY
   ```
2. **Also support TLS 1.2** — the domain-fronting fallback connects out from the
   server, and some providers block outbound TLS 1.3 by version.
3. Be plausible / unblocked for your audience.

Verified good (TLS 1.3 + 1.2): `avito.ru`, `ya.ru`, `vk.com`, `ozon.ru`,
`dzen.ru`, `yandex.ru`. Bad (1.2-only): `drom.ru`, `mail.ru`.

## Port

- **443** blends best with normal HTTPS and passes networks that only allow 443.
- **8443** keeps 443 free for another TLS service (e.g. Xray/Reality later).

## Manage

telemt:

```bash
journalctl -u telemt -f            # logs (journald handles rotation)
systemctl restart telemt           # restart (survives reboot: enabled)
# rotate secret:
sudo NEW_SECRET=1 DOMAIN=vkvideo.ru PORT=443 bash setup-telemt-node.sh
```

telemt WEB side:

```bash
# runtime status (sessions, capacity, carrier negotiation outcomes)
curl -sS -H "Authorization: Bearer $(cat /var/lib/telemt/api-token)" \
  http://127.0.0.1:9091/v1/runtime/web/status
# live sessions / close them
curl -sS -H "Authorization: Bearer $(cat /var/lib/telemt/api-token)" \
  http://127.0.0.1:9091/v1/runtime/web/sessions
# rotate the WEB secret (then re-issue links):
sudo NEW_SECRET=1 WEB_HOST=cdn.example.com bash setup-telemt-web-node.sh
```

mtg:

```bash
docker logs -f mtproto-proxy      # logs
docker restart mtproto-proxy      # restart (survives reboot: unless-stopped)
# rotate secret:
sudo NEW_SECRET=1 DOMAIN=ya.ru PORT=8443 bash setup-mtg-node.sh
```

## `python-proxy/` — legacy pure-Python implementation

The original Python MTProto proxy (fork lineage of alexbers/mtprotoproxy) lives
in [`python-proxy/`](python-proxy/). It works, but its fake-TLS ServerHello is
**not validated against the April-2026 fingerprint detection** — use telemt or
`mtg` above for production. Kept for reference and no-Docker / multi-user cases.
