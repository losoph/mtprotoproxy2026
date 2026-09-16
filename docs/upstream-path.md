# The node's egress to Telegram, and the middle-proxy playbook

A WEB proxy can be perfect on the client side and still be unusable, because the
node's *own* path to the Telegram DCs is a separate problem. On a Russian network
it is the weak link, and it produces symptoms that look exactly like a broken
proxy: Telegram connects and then hangs, chats do not load, and every manual
check of the proxy passes.

## What was measured on tldw (2026-09-16)

| Signal | Result |
| --- | --- |
| `telemt-upstream-probe`, bad cycles | 8, **all 8 lost the DCs while the neutral controls (1.1.1.1, GitHub) stayed up** |
| telemt, `Connection timeout to` | 2525, of which **2478 to `149.154.167.51` (DC2)**, 31 to DC4, 15 to DC1 |
| telemt, `marked unhealthy` / `No healthy upstreams` / `Upstream recovered` | 1090 / 452 / 27 |
| ICMP to DC2 | 0% loss, 45 ms, stable |
| Spot check, 20 rounds × 4 DC addresses | once 6/20 failed on **all four addresses in the same rounds**, later 20/20 clean |
| Host | load 0.00, 100% idle, conntrack 156/262144 — never the bottleneck |
| Other consumers | `tndr-bot` (Bot API) loops on `TelegramNetworkError: Request timeout`; `unagi-bot` (MTProto) talks to the same `149.154.167.51` |

Read together: the loss is episodic, hits Telegram ranges only, leaves ICMP and
neutral destinations untouched, concentrates on one DC address, and affects three
independent consumers on the box. That is the signature of filtering on Telegram
ranges somewhere in the provider's path, not congestion, not this host, and not
the proxy's configuration. `TcpRetransSegs ≈ TcpExtTCPTimeouts` in every sample,
i.e. recoveries are RTO-driven (packets dropped) rather than fast retransmits.

Keep collecting with the tooling rather than by hand:

```bash
journalctl -u telemt-upstream-probe --since '24 hours ago' | grep summary
telemt-probe-report.sh --to you@example.com --dry-run     # full picture, one screen
```

## ME mode was tried on tldw and does not work there (2026-09-16)

`USE_MIDDLE_PROXY=1` was applied and telemt could not start ME at all:

```
Proxy-secret download failed … core.telegram.org:443: Connection timeout to 149.154.167.99:443
ME startup failed: proxy-secret is unavailable and no saved secret found; falling back to direct mode
Transport: Direct DC startup fallback active; Middle-End bootstrap continues in background
```

That is the decisive measurement: the timeouts are not about one DC address but
about Telegram's prefixes as a whole — `core.telegram.org` (149.154.167.99) is in
the same `149.154.160.0/20` that DC2 lives in, and the middle-proxy endpoints ME
would use are in those prefixes too. Supplying the secret out of band
(`proxy_secret_path`) would therefore not rescue ME; it would only move the
failure one step later.

ME in this state is not neutral: telemt retries the bootstrap every ~5 s and each
failed attempt marks upstreams unhealthy, so the direct path degrades as well
(`No healthy upstreams available! Using random`). Leave `USE_MIDDLE_PROXY=0` on
this node until its egress changes.

## Middle-proxy mode: what it changes, and the trap on this node

`use_middle_proxy = true` routes through Telegram's own middle-proxy (ME)
endpoints instead of dialling DC addresses directly — different addresses,
different path, so it can survive filtering aimed at the DC ranges. It changes
only the node's upstream; the WEB transport towards clients is untouched.

**The trap:** ME key derivation uses the address Telegram sees. On tldw the
reflected address is not the node's own — startup logs
`STUN-Quorum reached, IP: 81.4.107.87` while the interface is `45.145.64.58`, so
the provider egresses through a different address. Enabling ME without telling
telemt about that produces failures that look nothing like their cause. Set one
of:

```toml
[general]
use_middle_proxy = true
middle_proxy_nat_ip = "45.145.64.58"   # manual public NAT address material
# or let it discover the mapping itself (needs network.stun_use):
# middle_proxy_nat_probe = true
```

The setup script exposes this as `USE_MIDDLE_PROXY=1` (and
`MIDDLE_PROXY_NAT_IP=`, which defaults to `PUBLIC_IP`), so switching is a line in
`/etc/telemt/deploy.env` plus `deploy.sh --force`, and the choice is recorded for
later deploys.

Also worth knowing before switching:

- ME mode needs Telegram's proxy secret and config, which telemt fetches over the
  same filtered path. If that fetch fails, startup logs say so — check them
  rather than assuming ME is working.
- It does nothing for the bots on the host: they reach Telegram on their own.
- `ad_tag` (from @MTProxybot) is only meaningful in ME mode; unrelated to whether
  the path works.

## Order of escalation

1. **Collect a full day** with the probe and the mailed report. A single quiet
   spot check means nothing; this fault is episodic.
2. **If bad cycles are DC-only**: `USE_MIDDLE_PROXY=1` with the NAT address set
   is the cheap thing to try — but on tldw it was tried and failed at the
   proxy-secret fetch (above), because the filtering covers the prefixes and not
   a single address. Check the startup logs, don't assume it took.
3. **If bad cycles take the neutral controls with them**: it is the provider's
   link or transit, and no proxy setting fixes it. Take the timestamps to
   Selectel.
4. **If ME mode does not move the numbers** (tldw: it cannot even start): the
   egress has to leave the filtered network. Two shapes, both keeping the
   already-proven client side:

   - **Move the proxy to a node outside the filtered network.** Same scripts, a
     hostname pointed at the new address. A client in Russia then makes an
     ordinary HTTPS connection to an ordinary foreign site, which is what WEB
     mode is for. fake-TLS also becomes worth re-enabling there for phones,
     which WEB does not serve. Simplest, one moving part.
   - **Keep the proxy here and tunnel only its egress** (WireGuard to a cheap
     foreign VPS, policy-routing Telegram prefixes — `149.154.160.0/20`,
     `91.108.4.0/22`, `91.108.8.0/21`, `91.108.16.0/21`, `91.108.56.0/22`,
     `91.105.192.0/23` — through it). Keeps clients on the local low-latency
     address and next to the existing site, at the cost of a tunnel to keep
     alive and routing that must survive reboots.

   Note what does *not* change either way: the bots on this host reach Telegram
   on their own and keep failing until their traffic is routed too.
