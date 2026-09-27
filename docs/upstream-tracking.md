# Which upstreams still matter, and why we do not auto-upgrade

## WEB mode did not take us out of MTProxy

A reasonable assumption after moving to the WEB proxy type is that the MTProxy
implementations stop being our problem. They do not. WEB is a **carrier**, not a
protocol replacement: telemt's own description is that WEB mode "carries ordinary
MTProxy streams through bounded HTTPS or WebSocket carriers". Inside the carrier
the node still speaks MTProxy — the links use `dd`/`plain` 16-byte MTProxy
secrets, each logical stream performs an inner MTProxy handshake, and the relay to
the Telegram DCs is the same MTProto machinery with the same DC routing, ME mode
and quota accounting.

What the move **did** retire, and we no longer track:

- fake-TLS ServerHello fingerprinting (JA3/JA4) and the arms race around it,
- the fronting domain (`tls_domain`) and its TLS-1.2/1.3 requirements,
- `client_mss` TSPU ServerHello fragmentation,
- `ee` secrets and the domain embedded in them.

What it **added**, and now has to be tracked instead:

- the WEB carrier protocol itself — young (landed August–September 2026), defined
  jointly by Telegram Desktop's client and the `tproxy-server` PoC, and still
  changing: carrier negotiation headers, the bridge document, lane semantics,
  recovery rules,
- the client side: a Desktop release can change negotiation metadata, and iOS
  supports only the `https` carrier,
- the TLS terminator's contract with it (Upgrade headers, timeouts vs the 25 s
  long poll, whole-vhost routing) — ours lives in `setup-telemt-web-node.sh`.

So the watch list changes shape rather than shrinking. Net: **more** reason to
follow releases than before, because the young half of the stack is the one we
depend on for every client connection.

## The watch list (September 2026)

| Repo | Why |
| --- | --- |
| [`telemt/telemt`](https://github.com/telemt/telemt) | what runs here; WEB, MTProxy core, ME, DC handling |
| [`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server) | Telegram's own WEB PoC — protocol changes show up here first |
| [`telegramdesktop/tdesktop`](https://github.com/telegramdesktop/tdesktop) | the client half of WEB; a release can change what clients negotiate |
| [`scratch-net/telego`](https://github.com/scratch-net/telego) | another implementation with WEB support; useful as a second reading of a protocol change |
| [`9seconds/mtg`](https://github.com/9seconds/mtg) | the documented fake-TLS fallback in this repo |

`tools/weekly-report.sh` reports the latest release of each, with the keywords its
notes mention (`web`, `carrier`, `security`, `middle`, …), next to the version
pinned in `/etc/telemt/deploy.env`. A node also has `ghsub` watching these repos;
pass its state path as `GHSUB_STATE=` if you want the report to reference it.

## Why upgrades are reported, not applied

The binary version is pinned in `deploy.env` and applied by a deploy. That is
deliberate, and the September 2026 history is the argument:

- **Releases move fast and change behaviour.** 3.5.0 → 3.5.8 in about five weeks.
  3.5.0 had no WEB at all; 3.5.1 added the HTTPS carriers; 3.5.4 the WebSocket
  ones; 3.5.6 added operator lifecycle controls; 3.5.8 (2026-09-27) introduces
  path-scoped WEB ingress with `base_path`. An unattended upgrade would have
  walked a production endpoint through all of that at 4 a.m.
- **Upstream itself asks for an acceptance step.** telemt's WEB guide states that
  end-to-end validation against the intended Telegram Desktop build and the real
  public TLS endpoint "remains an operator acceptance step".
- **We have one node and no canary.** A bad upgrade is a full outage, and the
  clients that matter (`websocket-lanes` sessions) cannot be replayed in a test.
- **We already watched an automated retry loop hurt.** When the WEB readiness
  check failed spuriously, the deploy timer re-ran it every five minutes and
  restarted telemt each time. Automation that installs new binaries on the same
  schedule earns the same failure mode with worse consequences.

So the loop is: the weekly report (or `ghsub`) names a new tag → read the release
notes → bump `TELEMT_VERSION` in a commit → the deploy applies it within five
minutes → verify (`decoy=200`, `site` unchanged, a real client reaching
`state: healthy`). One human decision, one commit, full audit trail, and the
rollback is the previous commit.

Worth automating instead, and already is: **noticing**. Version drift, a release
whose notes mention `web` or `security`, an endpoint that stopped answering, a
certificate about to expire, egress that started flapping again — all in one
weekly mail, plus the existing alerting for anything acute.

## When a release does warrant moving quickly

Skip the weekly rhythm and bump the same day when the notes mention:

- a security fix in code paths we expose (WEB ingress, the control API, admission
  or rate limiting),
- a WEB protocol or compatibility change — those can break clients silently, and a
  Desktop update on the other side may force our hand,
- anything about the carrier negotiation or bridge format while our clients are on
  `websocket-lanes`.

Everything else waits for a deliberate moment, because a restart drops live WEB
sessions.
