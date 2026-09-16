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

**First reading (wrong, kept as a warning):** loss that is episodic, hits only
Telegram addresses, leaves ICMP and neutral destinations alone, and affects three
independent consumers looks exactly like filtering of Telegram prefixes. It is
not, on this node.

## What it actually was: one VPN account used by two tunnels

This node routes Telegram prefixes into an OpenVPN tunnel (`tun10`/`tun11`,
`openvpn-client@tldw-{main,media}`), and Google prefixes into the other. Both
connect to **the same server** (`nl3.pvpn.pw`) with **the same credential**, so
both get the same client address, `192.168.101.4`.

An OpenVPN server without `duplicate-cn` evicts the previous session when the same
certificate connects again. The evicted client learns nothing over UDP and only
notices at `ping-restart`, about three minutes later — then it reconnects and
evicts the other one. Forever:

```
496 Initialization Sequence Completed in 24 h  (one every ~3 min)
[nl3.pvpn.pw] Inactivity timeout (--ping-restart), restarting   # alternating pids
```

Both configs use `route-nopull`, so the prefix routes are laid by an external
script on each tunnel-up event. With the tunnels restarting in turn, the Telegram
prefixes bounce between `tun10` and `tun11` — `ip route get` said `dev tun10`
while a `tcpdump` six minutes later caught the traffic on `tun11`. Each bounce
kills connections in flight and times out new ones, on every Telegram address at
once, while `eth0` destinations never notice.

That is the whole fault: telemt's 2478 timeouts and 452 "No healthy upstreams",
the probe's DC-only bad cycles, and the bots' constant `TelegramNetworkError`.
Not TSPU, not the prefixes, not the proxy.

Note what the other evidence really meant, once this is known:

- `rp_filter = 2` (loose) everywhere, and the `tcpdump` showed request *and* reply
  on the same interface — so there was never an asymmetry problem to fix.
- STUN reporting `81.4.107.87` while the interface is `45.145.64.58` is simply the
  VPN exit address: STUN went out through a tunnel. So for ME mode,
  `middle_proxy_nat_ip = "45.145.64.58"` is **wrong** on this node — Telegram sees
  the tunnel's exit, which changes on reconnect. `middle_proxy_nat_probe = true`
  is the only sane setting here, and only once the tunnels are stable.
- The two tunnels give no geographic spread at all: they terminate on the same
  server.

### Fixing it

1. **One tunnel, not two on one account.** Stop the redundant unit and put both
   prefix sets on the survivor (`tun11` demonstrably reaches Telegram at 41 ms).
   Free, immediate, removes the eviction loop.
2. **Or a second credential** from the provider, so two simultaneous sessions are
   legitimate. Only worth it if the tunnels are meant to terminate somewhere
   different — which today they do not.
3. Regardless: the route-laying script must pin each prefix set to one device
   deterministically, and `tun-mtu 1400` with `mssfix` removes the reliance on
   fragmentation that an MTU of 1500 inside a tunnel guarantees.
4. **Or remove the tunnels from the picture** by putting the proxy on a node
   outside the filtered network, where egress to Telegram needs no tunnel. Today
   the proxy's stability depends on how `pvpn.pw` hands addresses to two
   connections — a link nobody here controls.

## ME mode was tried on tldw and does not work there (2026-09-16)

`USE_MIDDLE_PROXY=1` was applied and telemt could not start ME at all:

```
Proxy-secret download failed … core.telegram.org:443: Connection timeout to 149.154.167.99:443
ME startup failed: proxy-secret is unavailable and no saved secret found; falling back to direct mode
Transport: Direct DC startup fallback active; Middle-End bootstrap continues in background
```

`core.telegram.org` (149.154.167.99) is in the same `149.154.160.0/20` as DC2, so
whatever breaks the DC path breaks the ME bootstrap too. But this is **not** a
permanent block: minutes later the same process logged
`Downloaded proxy-secret OK len=128`. ME failed because it happened to start
during an outage window, not because the fetch is impossible — do not read the
first conclusion here as "ME can never work".

**This node routes Telegram prefixes over OpenVPN tunnels.** That reframes the
probe's "DCs failed, neutral controls held" signature: the controls (1.1.1.1,
GitHub) leave through `eth0` while the Telegram prefixes leave through a tunnel,
so a flapping tunnel or a blocked VPN endpoint produces exactly the same picture
as upstream filtering. The probe cannot tell them apart — it does not record
which interface a destination leaves by. Diagnose the tunnels before concluding
anything about censorship, and before moving the node.

ME in this state is not neutral: telemt retries the bootstrap every ~5 s and each
failed attempt marks upstreams unhealthy, so the direct path degrades as well
(`No healthy upstreams available! Using random`). Keep `USE_MIDDLE_PROXY=0` until
the tunnel situation is understood; retry it only from a known-good path, so a
failure means something.

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
