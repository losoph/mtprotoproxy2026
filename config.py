import os

# --- Per-instance / secret settings come from the environment ---
# Do NOT hardcode the secret here again. Put it in a local .env file
# (git-ignored, see .env.example). Generate one with: openssl rand -hex 16
#
# When running under docker compose the .env file is passed into the
# container via `env_file:` in docker-compose.yml. When running bare
# (python3 mtprotoproxy.py) just export the variables first.

_secret = os.environ.get("MTPROTO_SECRET", "").strip().lower()
if not _secret:
    raise RuntimeError(
        "MTPROTO_SECRET is not set. Copy .env.example to .env, generate a "
        "secret with `openssl rand -hex 16`, and put it there."
    )

PORT = int(os.environ.get("MTPROTO_PORT", "443"))

# name -> secret (32 hex chars)
USERS = {
    "tg": _secret,
    # Add more users as "name": "32-hex-char-secret" if needed.
    # "tg2": "0123456789abcdef0123456789abcdef",
}

MODES = {
    # Classic mode, easy to detect
    "classic": False,

    # Makes the proxy harder to detect
    # Can be incompatible with very old clients
    "secure": True,

    # Makes the proxy even more hard to detect
    # Can be incompatible with old clients
    "tls": True
}

# The domain for TLS mode, bad clients are proxied there.
# Use a real existing TLS 1.3 domain; the proxy checks it on start.
# The tls_probe_rotator may auto-switch this to the best-performing domain.
TLS_DOMAIN = os.environ.get("MTPROTO_TLS_DOMAIN", "vk.com")

# Default profile: medium VDS (1-2 vCPU / 1GB RAM).
# Balanced for stable operation under moderate load.

# Keep direct mode by default to reduce complexity/cpu overhead.
USE_MIDDLE_PROXY = False
FAST_MODE = True
PREFER_IPV6 = False

# Backpressure / overload protection.
MAX_ACTIVE_CLIENTS = 500
ACCEPT_QUEUE_TIMEOUT = 1.2

# Buffers tuned for 1GB RAM (higher throughput, still bounded).
TO_CLT_BUFSIZE = (16384, 120, 131072)
TO_TG_BUFSIZE = (16384, 120, 131072)

# Client-side timeouts/keepalive.
CLIENT_HANDSHAKE_TIMEOUT = 12
CLIENT_KEEPALIVE = 10 * 60
CLIENT_ACK_TIMEOUT = 5 * 60

# Upstream connect resilience.
TG_CONNECT_TIMEOUT = 10
TG_CONNECT_RETRIES = 2
TG_RETRY_BACKOFF_BASE = 0.15
TG_RETRY_BACKOFF_MAX = 1.0
TG_RETRY_JITTER = 0.2

# Upstream socket tuning.
TG_KEEPALIVE = 40
TG_KEEPALIVE_ATTEMPTS = 5
TG_ACK_TIMEOUT = 60
TG_READ_TIMEOUT = 75
TG_POOL_SIZE = 12

# Circuit breaker / failover.
CIRCUIT_BREAKER_FAILS = 5
CIRCUIT_BREAKER_OPEN_SECS = 30
UPSTREAM_FAILOVER_ATTEMPTS = 3

# Health-check (balanced overhead/coverage).
UPSTREAM_HEALTHCHECK_PERIOD = 30
UPSTREAM_HEALTHCHECK_TIMEOUT = 3
UPSTREAM_HEALTHCHECK_SAMPLE = 16

# Operational visibility.
METRICS_PORT = 9090
METRICS_LISTEN_ADDR_IPV4 = "127.0.0.1"
METRICS_WHITELIST = ["127.0.0.1", "::1"]
STATS_PRINT_PERIOD = 600

# External TLS reachability probes (observability only).
TLS_PROBE_DOMAINS = [
    "ya.ru",
    "yandex.ru",
    "vk.com",
    "mail.ru",
    "gosuslugi.ru",
    "sberbank.ru",
    "ozon.ru",
    "wildberries.ru",
    "avito.ru",
    "rambler.ru",
]
TLS_PROBE_ROTATION_PERIOD = 3 * 60 * 60
TLS_PROBE_TIMEOUT = 4
TLS_PROBE_HISTORY_HOURS = 6
TLS_PROBE_MIN_SAMPLES = 3

# Tag for advertising, obtainable from @MTProxybot
# AD_TAG = "3c09c680b76ee91a4c25ad51f742267d"
