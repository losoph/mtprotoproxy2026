# python-proxy — alternative pure-Python MTProto proxy

Pure-Python MTProto proxy (fork lineage of
[alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)) with local
resilience extras: env-based secret, per-IP probe cutoff, circuit breaker /
connection pool, TLS record-size mimicry, optional email alerts.

## ⚠️ Status: secondary / not fingerprint-validated

The primary, production path for this repo is the `mtg` setup in the root
[`README`](../README.md). Use that unless you specifically need something here.

This implementation's fake-TLS **ServerHello is not validated against the
April-2026 TSPU JA3/JA4 detection**. It does *not* emit the GREASE-cipher bug
`mtg` had, but no JA3S audit was done. Treat it as reference / lab, or for:

- **no-Docker** deployments (`python3 mtprotoproxy.py`),
- **multi-user** secrets and per-user limits,
- environments where you want to read/modify the proxy logic directly.

## Run

```bash
cp .env.example .env    # set MTPROTO_SECRET (openssl rand -hex 16)
docker-compose up -d    # or: set -a; . .env; set +a; python3 mtprotoproxy.py
```

See [`DEPLOY.md`](DEPLOY.md) for the full guide. Config in `config.py`.
