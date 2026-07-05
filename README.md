# mtprotoproxy2026

Ready-to-deploy **MTProto proxy for a single VPS** — a curated, current
set of settings and one bootstrap script, tuned for the 2026 Russian DPI
(TSPU) reality. Not a code fork: it packages the tested, maintained proxy
(`9seconds/mtg`, fake-TLS) plus a lean hardening baseline that survives
re-installs and reboots.

> Scope: a clean MTProto node. No tunnels, no gateways, no host-specific glue.
> Bring it up on any fresh Ubuntu VPS in one command.

## Quick start

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

The secret embeds a domain the handshake impersonates. It must:

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

```bash
docker logs -f mtproto-proxy      # logs
docker restart mtproto-proxy      # restart (survives reboot: unless-stopped)
# rotate secret:
sudo NEW_SECRET=1 DOMAIN=ya.ru PORT=8443 bash setup-mtg-node.sh
```

## `python-proxy/` — alternative pure-Python implementation

An earlier Python MTProto proxy (fork lineage of alexbers/mtprotoproxy) lives
in [`python-proxy/`](python-proxy/). It works, but its fake-TLS ServerHello is
**not validated against the April-2026 fingerprint detection** — use the `mtg`
setup above for production. Kept for reference and no-Docker / multi-user cases.
