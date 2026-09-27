# Plan for the next session

State as of 2026-09-27, end of session. The WEB proxy works; what is left is one
untested claim, one open decision, and a handful of follow-ups.

## Where things stand

| | |
| --- | --- |
| Proxy | telemt **3.5.8**, WEB only, `cdn.orangerd.ru` — verified with a real Desktop client (`websocket-lanes`, `healthy`) |
| Site | `tldw.orangerd.ru` over HTTPS, cert 79 days left, renewal hook in place |
| Egress | one tunnel (`tldw-media`/`tun11`), routes laid by `tldw-routes-up.sh` from both lists, reconnects 3-per-10-min → 0 |
| Deploy | `deploy.sh` timer on `main`; the version pin lives in the repo, not in `deploy.env` |
| Reports | probe every 30s; weekly digest Sunday 08:00 via root crontab, through the node's ops library |
| tldw PR | [`losoph/tldw#10`](https://github.com/losoph/tldw/pull/10) — health checks for this topology |

## 1. The thing that still is not proven

**Desktop through a Russian mobile carrier (MegaFon/MTS), no VPN, held open for
ten minutes.** Everything measured so far was over a VPN or a home line, which
says nothing about TSPU. Until that test exists, "the WEB proxy works" means "the
WEB proxy works on an unfiltered path".

While testing, watch `journalctl -u telemt -f` and
`/v1/runtime/web/sessions`: the carrier that gets chosen on a mobile path may
differ from `websocket-lanes`, and a session that dies before 30 s shows up as
`closed_before_health` rather than as an error.

## 2. Read the first full weekly report

It arrives Sunday 08:00 MSK. The numbers to check against this session's
baseline (`docs/upstream-path.md` has the "before" table):

- tunnel reconnects: should be **≈0**, was 496/day;
- egress moves: **0**;
- probe bad cycles: was 63 in the week *before* the fix — expect a collapse;
- `installed` == `pinned` == 3.5.8;
- certificate days counting down from 79, and `ghsub last run` recent.

If reconnects are back, the eviction loop returned (a second tunnel on the same
credential) — `docs/upstream-path.md` has the mechanism.

## 3. Decisions waiting

- **Phones have no way in.** fake-TLS is off, and WEB exists only in Desktop.
  Re-enabling it beside WEB is `KEEP_MTPROTO=1` + `PORT=8443` in `deploy.env`
  plus re-issued links (old secret in `/root/telemt-config.toml.bak`). Worth
  doing if anyone but you uses this proxy from a phone.
- **`base_path` (new in 3.5.8)** could put the proxy under a path of an existing
  site instead of a dedicated hostname. Tempting, but the decoy contract has to
  be re-thought first, and the terminator must pass the full path untouched. See
  `docs/upstream-tracking.md`.
- **Rotate the WEB secret.** It has been pasted in plain text into a chat
  transcript, and telemt prints it to journald on every start. Command is in
  `docs/nodes/tldw.md`.

## 4. Follow-ups, small

- `tun-mtu 1400` + `mssfix 1360` in `tldw-media.conf`: an MTU of 1500 inside a
  tunnel guarantees fragmentation on every large packet.
- After [`tldw#10`](https://github.com/losoph/tldw/pull/10) merges, enable the new
  checks in `/etc/tldw/health.env`: `TUNNEL_TEST_IP=149.154.167.51`,
  `TELEMT_LISTEN=127.0.0.1:18080`, `NGINX_UNIT=nginx`,
  `CERT_DOMAIN=cdn.orangerd.ru`, `CERT_MIN_DAYS=14`. Then confirm one health run
  reports `nginx OK` and `telemt OK (127.0.0.1:18080)`.
- Star the upstream repos listed in `docs/upstream-tracking.md` so `ghsub` surfaces
  their releases; the weekly report only reports drift, it is not a watcher.
- `ghsub`'s own `bin/ghsub-digest.sh` header says "Cron: понедельник 07:00" while
  its README and the crontab say Sunday (`0 7 * * 0`). One of them is wrong.
- The Remote Desktop Commander device (`MacBook-Pro-rim.local`) has been offline
  since 2026-09-23. Bringing it online lets the next session run diagnostics over
  ssh itself instead of handing over command blocks.

## 5. If the proxy is reported broken

Check in this order — the September incident was in step 2, and three days of
measurements went into steps 1 and 3 before anyone looked at the tunnel:

1. `curl` the public endpoint: `decoy=200` on the proxy host, `site=401` on the
   site. A `200` on the site means nginx is serving the decoy instead.
2. **The egress path**: `ip route get 149.154.167.51` (expect `tun11`),
   `journalctl -u 'openvpn*' --since '1 hour ago' | grep -c 'Initialization Sequence'`,
   `journalctl -u telemt-upstream-probe --since today | grep 'egress moved'`.
3. telemt itself: `/v1/runtime/web/status` for `lifecycle` and live acceptors,
   `/v1/runtime/web/sessions` for what clients actually negotiated.
4. Only then the client side, and only with `[web.debug] enabled = true` if you
   need per-request detail.
