# Working on this repo

This repo is not a library: it is the configuration of live proxy nodes, kept in
git so a node can be rebuilt or fixed from a commit. Read [`README.md`](README.md)
for what each script does, and the docs below before touching a running node.

- [`docs/nodes/tldw.md`](docs/nodes/tldw.md) — the node currently in production:
  what runs on it, which ports belong to whom, and every decision already taken.
- [`docs/upstream-path.md`](docs/upstream-path.md) — the node's egress to the
  Telegram DCs, the measurements taken so far, and the middle-proxy playbook.

## Rules that cost us something to learn

- **Never hand-edit `/etc/nginx/*` or `/etc/telemt/*` on a node.** A deploy
  overwrites it, and in between the box is in a state no commit describes. One
  `sed` on the generated vhost made the proxy vhost claim the site's hostname,
  and the site silently started serving the proxy's decoy page. Fix in the repo,
  push, deploy (`deploy.sh --force`).
- **Secrets never enter the repo, a commit message, or a PR body.** Node secrets
  live in `/var/lib/telemt/` (`web-secret`, `secret`, `api-token`). Rotation is
  always a deliberate manual run (`NEW_SECRET=1`), never a deploy — a deploy that
  rotated secrets would invalidate every user's link without anyone asking.
- **A changed script must survive re-running.** Every setup script is applied by
  the deploy timer on each new commit, on a box with users on it. Re-running is
  the normal case, not a recovery path.
- **The node's own clock is MSK (UTC+3)** and journald prints local time while
  telemt's own lines are UTC. Always say which one you mean when correlating an
  incident with a user complaint.

## Verification that actually proves something

- `site=401` on `https://tldw.orangerd.ru/` is the application (its own basic
  auth). `site=200` means nginx is serving the proxy's decoy instead — a
  regression, not a success.
- `decoy=200` and a plausible `404` on an unknown path on the proxy hostname is
  the anti-probing contract. Check it through the public endpoint, not locally.
- A WEB session is only proven by a real client: `state: healthy` with a
  `carrier` in `/v1/runtime/web/sessions`. The server being up proves nothing.
- Desktop connecting over a home line proves nothing about censorship. The test
  that counts is a Russian mobile carrier (MegaFon/MTS), no VPN, held open for
  ten minutes.

## Shape of a change

Develop on a branch, open a draft PR, merge into `main` when it is verified on
the node — the deploy timer follows `main`. Repo history is linear (rebase
merges). Don't add commits to a merged PR's branch; start a new one from `main`.
