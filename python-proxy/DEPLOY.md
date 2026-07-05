# Deploy — MTProto proxy (Ubuntu 24.04)

Развёртывание прокси на чистом VDS (KVM, 1 vCPU / 1 GB RAM / 10 GB NVMe,
dual-stack IPv4 + IPv6, локация София). Сервер используется **только** как
шлюз для Telegram, поэтому всё остальное на нём не нужно.

> **Безопасность секрета.** В коде секрета больше нет — `config.py` читает его
> из переменной `MTPROTO_SECRET` (файл `.env`, который игнорируется гитом).
> Старый секрет, который раньше лежал в репозитории, остаётся в истории git и
> считается скомпрометированным — **никогда его больше не используйте**, на
> проде генерируйте новый. Историю переписывать не обязательно: новый секрет в
> репозиторий не попадает.

---

## 1. Первичная настройка сервера

Под `root` по SSH:

```bash
# отдельный пользователь + sudo
adduser deploy && usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy/

# обновления и синхронизация времени
# (важно: прокси проверяет рассинхрон часов при fake-TLS handshake)
apt update && apt -y upgrade
timedatectl set-ntp true

# swap — на 1 ГБ ОЗУ обязателен как страховка от OOM
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Проверка, что поднялся IPv6 (из тарифа выдан 1 адрес):

```bash
ip -6 addr
```

## 2. Файрвол (ufw)

Контейнер запускается с `network_mode: host`, поэтому слушает порты хоста
напрямую — известного обхода ufw через Docker тут нет, правила работают как
обычно.

```bash
ufw allow OpenSSH
ufw allow 443/tcp        # порт прокси (см. MTPROTO_PORT в .env)
ufw enable
```

Порт метрик (`9090`) наружу открывать не нужно: в конфиге он привязан к
`127.0.0.1` и снаружи недоступен.

## 3. Docker + compose-плагин

Официальный репозиторий Docker:

```bash
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# чтобы работать под deploy без sudo
usermod -aG docker deploy
```

Перелогиньтесь под `deploy`. Команда — `docker compose` (v2), не
`docker-compose`.

## 4. Код на сервер

```bash
git clone https://gitlab.com/<ваш-путь>/mtproto.git
cd mtproto
```

## 5. Боевой конфиг (секрет через .env)

```bash
cp .env.example .env
openssl rand -hex 16        # скопировать вывод
nano .env                   # вставить в MTPROTO_SECRET
```

В `.env`:

- `MTPROTO_SECRET` — свежий секрет (обязательно, иначе прокси не стартует);
- `MTPROTO_PORT` — `443` рекомендуется: в TLS-режиме трафик маскируется под
  обычный HTTPS. Низкий порт работает без root — в `Dockerfile` уже стоит
  `setcap cap_net_bind_service` на python;
- `MTPROTO_TLS_DOMAIN` — `vk.com` нормально для аудитории из РФ; ротатор
  `tls_probe_rotator` всё равно сам подберёт лучший домен из списка в
  `config.py`.

Убедитесь, что `.env` НЕ попадает в git (он уже в `.gitignore`):

```bash
git status   # .env не должен отображаться
```

## 6. Сборка и запуск

Сборка лёгкая: `cryptography` ставится из apt, а не компилируется через pip,
поэтому 1 ГБ + swap хватает с запасом.

```bash
docker compose up -d --build
docker compose logs --tail=80
```

В логах будут готовые ссылки `tg://proxy?...` для каждого IP (v4 и v6) — это и
есть ссылки на прокси. `restart: unless-stopped` + включённый при загрузке
`docker` переживают перезагрузку сервера, отдельный systemd-юнит не нужен.

## 7. Проверка

```bash
ss -tlnp | grep -E ':(443|8443)'    # слушает ли порт
docker compose ps                   # контейнер в состоянии Up
```

Откройте `tg://`-ссылку из логов на телефоне — Telegram предложит подключить
прокси.

## 8. Эксплуатация

```bash
docker compose logs -f              # живые логи
docker compose restart              # перезапуск
docker compose down && docker compose up -d --build   # пересборка после правок
docker image prune -f               # подчистить старые образы (на диске 10 ГБ)
```

Смена секрета/порта/домена — правка `.env` и `docker compose up -d`
(перемонтирует переменные окружения; при смене порта обновите правило ufw).

### Метрики (опционально)

Prometheus-эндпойнт доступен только локально на `127.0.0.1:9090`. Чтобы
собирать метрики, ставьте Prometheus на этом же сервере или пробрасывайте порт
по SSH-туннелю. Правила алертов — в `prometheus-alerts.yml`.

---

## 9. Устойчивость: три механизма

### Feature 1 — уведомления об ошибках на почту (msmtp + Gmail)

При старте выполняется самопроверка (**doctor**): резолв и доступность
`MASK_HOST`, резолв `TLS_DOMAIN`, наличие `msmtp`. Любая нестандартная ошибка
в event-loop тоже триггерит письмо. Частота — **не чаще одного письма раз в 12
часов** (`ALERT_MIN_INTERVAL`), чтобы не спамить.

Письма уходят через `msmtp` с Gmail app-паролем. **Пароль не хранится в
репозитории** — он в `~/.msmtprc`, который монтируется в контейнер.

1. Включите 2FA в Google-аккаунте и создайте app-password
   (Google Account → Security → App passwords).
2. Создайте `./msmtprc` рядом с `docker-compose.yml`:

   ```ini
   defaults
   auth           on
   tls            on
   tls_trust_file /etc/ssl/certs/ca-certificates.crt
   logfile        ~/.msmtp.log

   account        gmail
   host           smtp.gmail.com
   port           587
   from           your_account@gmail.com
   user           your_account@gmail.com
   password       APP_PASSWORD_БЕЗ_ПРОБЕЛОВ

   account default : gmail
   ```

   ```bash
   chmod 600 ./msmtprc        # обязательно, иначе msmtp откажется работать
   ```

3. Раскомментируйте монтаж в `docker-compose.yml`:

   ```yaml
   - ./msmtprc:/home/tgproxy/.msmtprc:ro
   ```

4. В `.env` задайте получателя:

   ```bash
   MTPROTO_ALERT_EMAIL=your_account@gmail.com
   ```

`./msmtprc` тоже **не коммитим** (добавлен в `.gitignore`). Проверка вручную из
контейнера: `docker compose exec mtprotoproxy sh -c 'echo test | msmtp -- you@gmail.com'`.

### Feature 2 — лимит клиентов и отсечение зондов

- `MAX_ACTIVE_CLIENTS = 10` — не более 10 клиентов одновременно (глобально).
- `MAX_CONNS_PER_IP = 8` — не более 8 TCP-соединений с одного IP.
- **Отсечение зондов и одноразовых IP.** IP, который прислал плохой/пустой
  handshake (сканеры, DPI-зонды), помечается и **жёстко отбрасывается (RST)** на
  `PROBE_BAN_SECS` (по умолчанию 30 мин). Достаточно одного плохого handshake
  (`PROBE_FAIL_THRESHOLD = 1`). Реальный клиент после валидного MTProto-handshake
  становится «доверенным» и под бан не попадает **никогда** — поэтому легитимные
  новые пользователи не блокируются, а одноразовые зонды отсекаются дёшево.
- Память ограничена `IP_GREYLIST_LEN` (LRU), без утечек.
- Новые метрики Prometheus: `connects_dropped_probe`, `connects_dropped_per_ip`,
  `probe_ips_banned`.

### Feature 3 — мимикрия размеров TLS-записей

Раньше длина фейкового «сертификата» в fake-TLS ServerHello была случайной до
первого асинхронного запроса к `MASK_HOST`. Теперь:

- размеры реальных app-data записей `MASK_HOST` запоминаются и **точно
  воспроизводятся** в нашем ServerHello (приближает статистику к настоящему
  сайту, как DRS в mtg);
- длина забирается **синхронно на старте** (`TLS_MIMIC_PRIME_ON_START`), поэтому
  даже первые клиенты получают правдоподобный ответ — нет «окна» со случайной
  длиной.

Отключается флагами `TLS_MIMIC_RECORD_SIZES` / `TLS_MIMIC_PRIME_ON_START`.
