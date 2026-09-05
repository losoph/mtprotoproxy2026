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
