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
# Hard cap on simultaneously served clients (small personal proxy).
MAX_ACTIVE_CLIENTS = 10
ACCEPT_QUEUE_TIMEOUT = 1.2

# --- Per-IP limiting & probe cutoff (Feature 2) ---
# Max simultaneous TCP connections from one source IP (Telegram opens up to ~8).
MAX_CONNS_PER_IP = 8
# An untrusted IP that only ever sends bad/zero handshakes is treated as a probe
# and hard-dropped (RST) for this many seconds. A valid MTProto handshake makes
# the IP "trusted" and immune to this. So real users are never blocked; one-shot
# scanners/probes get cut off cheaply.
PROBE_BAN_SECS = 30 * 60
PROBE_FAIL_THRESHOLD = 1
IP_GREYLIST_LEN = 65536

# --- Email alerting via msmtp (Feature 1) ---
# Recipient of alert emails. Empty disables alerting. Set MTPROTO_ALERT_EMAIL in
# .env. The Gmail app-password lives in ~/.msmtprc (NOT here), see DEPLOY.md.
ALERT_EMAIL = os.environ.get("MTPROTO_ALERT_EMAIL", "")
ALERT_EMAIL_FROM = os.environ.get("MTPROTO_ALERT_FROM", ALERT_EMAIL)
# No more than one alert email per this interval (seconds). Default: 12 hours.
ALERT_MIN_INTERVAL = 12 * 60 * 60
ALERT_MSMTP_PATH = "msmtp"
# Run the startup self-check ("doctor") and alert about any problems found.
DOCTOR_ENABLED = True

# --- TLS record-size mimicry (Feature 3) ---
# Replay the MASK_HOST's real TLS app-data record sizes in our fake ServerHello,
# and fetch them synchronously on start so the first clients are already faithful.
TLS_MIMIC_RECORD_SIZES = True
TLS_MIMIC_PRIME_ON_START = True

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
