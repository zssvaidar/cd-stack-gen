#!/bin/bash
# project-14's Laravel app (project-14/laravel-app) run directly on the instance: Caddy on :80
# -> php-fpm over a unix socket, smoke-tested through Caddy before snapshot. Same shape as
# nodejs_caddy.sh. The container version of the same app is project-14/laravel-app/Dockerfile.
#
# Composer dependencies are installed on the builder (no dev packages) and Composer removed
# again. Frontend assets are not built - the welcome page falls back to inline styles without a
# Vite manifest, and /health doesn't need them. Health: /health (liveness), /health/ready
# (readiness, checks the database), Laravel's own /up - point an ALB target group at
# /health/ready.
#
# Secrets are NOT baked: laravel-app-init.service runs at every boot, before php-fpm. On first
# boot it creates /etc/laravel-app/app.env (the app's .env) with a fresh APP_KEY, then migrates
# and rebuilds Laravel's config/route/view caches. To use RDS instead of the instance-local
# SQLite file, have user-data write app.env first (one KEY=value per line), e.g.:
#   DB_CONNECTION=mysql
#   DB_HOST=mydb.xxxx.ap-northeast-1.rds.amazonaws.com
#   DB_DATABASE=laravel
#   DB_USERNAME=laravel
#   DB_PASSWORD=...
#   RUN_MIGRATIONS=true          # SQLite always migrates; anything else only with this set
# Keys user-data doesn't set (APP_KEY included) are filled in by the init.
#
# Build:
#   run.sh ami laravel-app laravel create
#   PROVISION_ENV="APP_REF=my-branch" run.sh ami laravel-app laravel create
#   PROVISION_ENV="APP_GIT_TOKEN_PARAM=/cd-stack-gen/git-token" run.sh ami laravel-app laravel create   # private repo
#
# Needs outbound internet while building (dnf, git, getcomposer.org, Packagist/GitHub).
# Inbound :80 on the instance's security group. Targets Amazon Linux 2023 (dnf), x86_64 or arm64.
set -euo pipefail

# --------------------------------------------------
# Settings - override with PROVISION_ENV (manage_ami.sh) or edit here
# --------------------------------------------------

# Where the app comes from:
#   s3://bucket/key.tar.gz        a `git archive` tarball of this repo; the builder's instance
#                                 profile needs s3:GetObject on it
#   https://host/owner/repo.git   git; private repos read a token from SSM (APP_GIT_TOKEN_PARAM)
APP_SOURCE="${APP_SOURCE:-https://github.com/zssvaidar/cd-stack-gen.git}"
APP_REF="${APP_REF:-master}"
# SSM SecureString holding a read-only token for APP_SOURCE. The builder's instance profile
# needs ssm:GetParameter on it. Never baked into the image.
APP_GIT_TOKEN_PARAM="${APP_GIT_TOKEN_PARAM:-}"
# The app's directory inside APP_SOURCE.
APP_SUBDIR="${APP_SUBDIR:-project-14/laravel-app}"
# Shared Grafana Alloy setup inside APP_SOURCE (see "Monitoring" below).
MONITORING_SUBDIR="${MONITORING_SUBDIR:-project-14/monitoring}"
# First PHP line Amazon Linux has packages for wins. Laravel 13 needs 8.3+.
PHP_VERSIONS="${PHP_VERSIONS:-8.4 8.3}"

APP_NAME=laravel-app
APP_DIR=/opt/$APP_NAME
CONF_DIR=/etc/$APP_NAME
APP_USER=laravel
FPM_SOCK=/run/php-fpm/$APP_NAME.sock

log() { echo "laravel.sh: $*"; }

# See nodejs.sh / README.md: Amazon Linux's background jobs can hold the rpm lock at any time.
retry_pkg() {
    local n=0 max=6
    until "$@"; do
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        echo "package manager busy (rpm lock held) - retry $n/$max in 5s" >&2
        sleep 5
    done
}


# --------------------------------------------------
# Packages. php8.x-pdo includes pdo_sqlite; mysqlnd/pgsql cover RDS MySQL/PostgreSQL.
# --------------------------------------------------

php=""
for v in $PHP_VERSIONS; do
    if dnf -q list --available "php$v-fpm" >/dev/null 2>&1 || rpm -q "php$v-fpm" >/dev/null 2>&1; then
        php="php$v"
        break
    fi
done
[[ -n "$php" ]] || { echo "laravel.sh: none of PHP $PHP_VERSIONS is available from dnf" >&2; exit 1; }
log "using $php"

retry_pkg dnf install -y git unzip tar \
    "$php-cli" "$php-fpm" "$php-common" "$php-mbstring" "$php-xml" "$php-pdo" \
    "$php-mysqlnd" "$php-pgsql" "$php-opcache" "$php-process" "$php-intl"
# Nice to have, not needed by the skeleton - don't fail the build if a line lacks one.
for ext in sodium bcmath zip; do
    retry_pkg dnf install -y "$php-$ext" || log "$php-$ext not available, skipped"
done

cat > /etc/php.d/99-$APP_NAME.ini <<'EOF'
expose_php = Off
memory_limit = 256M
upload_max_filesize = 20M
post_max_size = 20M
display_errors = Off
log_errors = On

; Code only changes with a new image (or a deploy that restarts php-fpm), so never stat files.
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
EOF

# Composer: official installer, verified against its published signature. Build-only.
log "installing composer (build only)"
expected=$(curl -fsSL https://composer.github.io/installer.sig)
curl -fsSL https://getcomposer.org/installer -o /var/tmp/composer-setup.php
actual=$(php -r "echo hash_file('sha384', '/var/tmp/composer-setup.php');")
[[ "$expected" == "$actual" ]] || { echo "laravel.sh: composer installer checksum mismatch" >&2; exit 1; }
php /var/tmp/composer-setup.php --quiet --install-dir=/var/tmp --filename=composer
rm -f /var/tmp/composer-setup.php


# --------------------------------------------------
# Source
# --------------------------------------------------

SRC=/var/tmp/app-src
rm -rf "$SRC"
mkdir -p "$SRC"

case "$APP_SOURCE" in
    s3://*)
        log "fetching $APP_SOURCE"
        aws s3 cp --only-show-errors "$APP_SOURCE" /var/tmp/app.tar.gz
        tar -xzf /var/tmp/app.tar.gz -C "$SRC"
        rm -f /var/tmp/app.tar.gz
        ;;
    https://*)
        log "cloning $APP_SOURCE @ $APP_REF"
        git_auth=()
        if [[ -n "$APP_GIT_TOKEN_PARAM" ]]; then
            token=$(aws ssm get-parameter --with-decryption --name "$APP_GIT_TOKEN_PARAM" --query Parameter.Value --output text)
            # header, not URL: the token never lands in .git/config or the process list
            git_auth=(-c "http.extraHeader=Authorization: Basic $(printf 'token:%s' "$token" | base64 -w0)")
            unset token
        fi
        git "${git_auth[@]}" clone --quiet --depth 1 --branch "$APP_REF" "$APP_SOURCE" "$SRC" || {
            echo "laravel.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "            or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        ;;
    *) echo "laravel.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

[[ -f "$SRC/$APP_SUBDIR/artisan" ]] || { echo "laravel.sh: no $APP_SUBDIR/artisan in $APP_SOURCE - wrong repo, ref or APP_SUBDIR?" >&2; exit 1; }


# --------------------------------------------------
# Install the app. Code is root-owned and read-only to the app user; only storage/,
# bootstrap/cache/ and database/ (the SQLite file) are writable.
# --------------------------------------------------

useradd --system --no-create-home --shell /sbin/nologin "$APP_USER" 2>/dev/null || true

rm -rf "$APP_DIR"
cp -a "$SRC/$APP_SUBDIR" "$APP_DIR"
rm -rf "$APP_DIR/vendor" "$APP_DIR/node_modules" "$APP_DIR/.env" "$APP_DIR"/database/*.sqlite
echo "$APP_SOURCE @ $APP_REF ($APP_SUBDIR), built $(date -u +%FT%TZ)" > "$APP_DIR/.source"

log "composer install (no dev)"
(
    cd "$APP_DIR"
    export COMPOSER_HOME=/var/tmp/composer-home COMPOSER_ALLOW_SUPERUSER=1
    /var/tmp/composer install --no-dev --optimize-autoloader --no-interaction --no-progress --prefer-dist
)

chown -R root:root "$APP_DIR"
chown -R "$APP_USER:$APP_USER" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" "$APP_DIR/database"

# The app's .env lives outside the code, so a new release (or image) never carries one.
mkdir -p "$CONF_DIR"
chmod 750 "$CONF_DIR"
chown "root:$APP_USER" "$CONF_DIR"
ln -sfn "$CONF_DIR/app.env" "$APP_DIR/.env"


# --------------------------------------------------
# First-boot / every-boot init: .env + APP_KEY, migrations, Laravel caches. Before php-fpm.
# --------------------------------------------------

cat > /usr/local/sbin/$APP_NAME-init.sh <<EOF
#!/bin/bash
set -euo pipefail
APP_DIR=$APP_DIR
ENV_FILE=$CONF_DIR/app.env
APP_USER=$APP_USER
EOF
cat >> /usr/local/sbin/$APP_NAME-init.sh <<'EOF'

artisan() { runuser -u "$APP_USER" -- php "$APP_DIR/artisan" "$@"; }
get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }
set_default() { [[ -n "$(get "$1")" ]] || echo "$1=$2" >> "$ENV_FILE"; }

touch "$ENV_FILE"
chown "root:$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

set_default APP_NAME Laravel
set_default APP_ENV production
set_default APP_DEBUG false
set_default APP_KEY "base64:$(head -c 32 /dev/urandom | base64)"
set_default DB_CONNECTION sqlite
# PHP's error log -> php-fpm's log -> syslog -> the journal, which Alloy ships to Loki
set_default LOG_CHANNEL errorlog

migrate=$(get RUN_MIGRATIONS)
if [[ "$(get DB_CONNECTION)" == "sqlite" ]]; then
    db=$(get DB_DATABASE)
    db=${db:-$APP_DIR/database/database.sqlite}
    [[ -f "$db" ]] || runuser -u "$APP_USER" -- touch "$db"
    migrate=true
fi

if [[ "$migrate" == "true" ]]; then
    artisan migrate --force
fi
# env may have changed since the last boot - always rebuild the caches from it
artisan config:cache
artisan route:cache
artisan view:cache
EOF
chmod 755 /usr/local/sbin/$APP_NAME-init.sh

cat > /etc/systemd/system/$APP_NAME-init.service <<EOF
[Unit]
Description=project-14 Laravel app - .env, migrations, caches
# user-data (write_files) runs in cloud-init.service - let it write app.env first
After=network-online.target cloud-init.service
Wants=network-online.target
Before=php-fpm.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/$APP_NAME-init.sh

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/php-fpm.service.d
cat > /etc/systemd/system/php-fpm.service.d/$APP_NAME.conf <<EOF
[Unit]
Requires=$APP_NAME-init.service
After=$APP_NAME-init.service
EOF


# --------------------------------------------------
# php-fpm: one pool for the app, as $APP_USER, on a socket only Caddy can reach. The distro's
# "www" pool (as apache) is dropped. Logs go to syslog (the journal). The pool's status page
# feeds Alloy's metrics scrape (OpenMetrics, see Caddy below).
# --------------------------------------------------

rm -f /etc/php-fpm.d/www.conf
sed -i 's|^;*error_log = .*|error_log = syslog|' /etc/php-fpm.conf
grep -q '^error_log = syslog' /etc/php-fpm.conf || echo 'error_log = syslog' >> /etc/php-fpm.conf
cat > /etc/php-fpm.d/$APP_NAME.conf <<EOF
[$APP_NAME]
user = $APP_USER
group = $APP_USER
listen = $FPM_SOCK
listen.owner = caddy
listen.group = caddy
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500
pm.status_path = /fpm-status

catch_workers_output = yes
decorate_workers_output = no
EOF

systemctl daemon-reload
systemctl enable $APP_NAME-init.service php-fpm.service


# --------------------------------------------------
# Caddy: :80 -> php-fpm (php_fastcgi, Laravel's front controller) and static files from
# public/. Access log (JSON) to the journal for Loki, health probes left out.
# 127.0.0.1:9180/metrics serves php-fpm's status page as OpenMetrics, for Alloy only.
# Installed like nodejs_caddy.sh: the official release tarball (Caddy isn't in Amazon Linux's
# repos), pinned with sha512 from caddy_<version>_checksums.txt - bump both scripts together.
# --------------------------------------------------

CADDY_VERSION=2.10.2
declare -A CADDY_SHA512=(
    [amd64]=747df7ee74de188485157a383633a1a963fd9233b71fbb4a69ddcbcc589ce4e2cc82dacf5dbbe136cb51d17e14c59daeb5d9bc92487610b0f3b93680b2646546
    [arm64]=6ce061a690312ab38367df3c5d5f89a2e4a263e7300d300d87356211bb81e79b15933e6d6203e03fbf26f15cc0311f264805f336147dbdd24938d84b57a4421c
)

case "$(uname -m)" in
    x86_64) caddy_arch=amd64 ;;
    aarch64) caddy_arch=arm64 ;;
    *) echo "laravel.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

caddy_tgz=$(mktemp)
curl -fsSL --retry 5 -o "$caddy_tgz" \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz"
echo "${CADDY_SHA512[$caddy_arch]}  $caddy_tgz" | sha512sum -c --quiet - \
    || { echo "laravel.sh: checksum mismatch for caddy $CADDY_VERSION" >&2; exit 1; }
tar -xzf "$caddy_tgz" -C /usr/local/bin caddy
chmod 0755 /usr/local/bin/caddy
rm -f "$caddy_tgz"

# runs unprivileged; its home is where Caddy keeps its data (certificates, if TLS is turned on)
useradd --system --home-dir /var/lib/caddy --create-home --shell /sbin/nologin caddy 2>/dev/null || true

mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
{
	# Behind a load balancer: trust X-Forwarded-For from private ranges, so the app sees the
	# real client IP rather than the balancer's.
	servers {
		trusted_proxies static private_ranges
	}
}

# ":80" = any hostname, plain HTTP - a bare port gets no automatic HTTPS (see nodejs_caddy.sh).
:80 {
	root * $APP_DIR/public
	encode

	# access log (JSON) to stderr -> journal (caddy.service) -> Alloy -> Loki; probes left out
	log
	@probes path /health /health/* /up
	log_skip @probes

	# index.php front controller, like Laravel's own docs for Caddy
	php_fastcgi unix/$FPM_SOCK
	file_server {
		hide .*
	}
}

# php-fpm's status page as OpenMetrics, for Alloy only. /fpm-status itself isn't reachable on
# :80 - it isn't a file, so php_fastcgi hands it to Laravel, which 404s.
http://127.0.0.1:9180 {
	bind 127.0.0.1
	log_skip

	handle /metrics {
		rewrite * /fpm-status?openmetrics
		reverse_proxy unix/$FPM_SOCK {
			transport fastcgi {
				# no site root here: name the status page directly, as php-fpm expects
				env SCRIPT_NAME /fpm-status
				env SCRIPT_FILENAME /fpm-status
			}
		}
	}
	respond 404
}
EOF

/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# the upstream caddy.service, with the binary at /usr/local/bin
cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy.service


# --------------------------------------------------
# Monitoring: Grafana Alloy ships host metrics, php-fpm metrics, a health probe and the journal
# of these units to the monitoring host (grafana.sh). Off until /etc/alloy/endpoint.env exists -
# see project-14/monitoring/alloy/install.sh.
# --------------------------------------------------

export APP_NAME
APP_METRICS_ADDR=127.0.0.1:9180 APP_METRICS_PATH=/metrics \
APP_HEALTH_URL=http://127.0.0.1/health/ready \
LOG_UNITS="php-fpm.service|caddy.service|$APP_NAME-init.service" \
    bash "$SRC/$MONITORING_SUBDIR/alloy/install.sh"


# --------------------------------------------------
# Drop Composer and the sources.
# --------------------------------------------------

rm -rf "$SRC" /var/tmp/composer /var/tmp/composer-home


# --------------------------------------------------
# Smoke test through Caddy before this becomes a snapshotted image - then remove everything the
# init generated (.env with its APP_KEY, the SQLite file, caches, logs) so each instance
# generates its own on first boot.
# --------------------------------------------------

ok=true
systemctl start $APP_NAME-init.service || ok=false
systemctl start php-fpm.service || ok=false
systemctl restart caddy.service || ok=false

curl -fsS http://127.0.0.1/health/ready | grep -q '"database":"UP"' || ok=false
curl -fsS -o /dev/null http://127.0.0.1/up || ok=false
curl -fsS -o /dev/null http://127.0.0.1/ || ok=false
curl -fsS http://127.0.0.1:9180/metrics | grep -q '^phpfpm_up 1' || ok=false
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/fpm-status | grep -q 404 || ok=false

systemctl stop caddy.service php-fpm.service || true
systemctl stop $APP_NAME-init.service || true

if [[ "$ok" != "true" ]]; then
    echo "laravel.sh: smoke test failed - app not reachable through Caddy" >&2
    journalctl -u $APP_NAME-init -u php-fpm -u caddy --no-pager -n 50 >&2 || true
    tail -n 50 "$APP_DIR"/storage/logs/*.log /var/log/php-fpm/*.log >&2 2>/dev/null || true
    exit 1
fi
echo "laravel.sh: smoke test passed - app reachable through Caddy"

# config/route/view/event caches only - packages.php + services.php came from composer and stay
rm -f "$CONF_DIR/app.env" "$APP_DIR"/database/*.sqlite \
      "$APP_DIR"/bootstrap/cache/config.php "$APP_DIR"/bootstrap/cache/routes-*.php "$APP_DIR"/bootstrap/cache/events.php
find "$APP_DIR/storage/logs" "$APP_DIR/storage/framework/cache" "$APP_DIR/storage/framework/sessions" \
     "$APP_DIR/storage/framework/views" -type f ! -name .gitignore -delete
