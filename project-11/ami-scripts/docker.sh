#!/bin/bash
# Docker host running the whole accounting suite (github.com/zssvaidar/full-stackapps) on one
# instance: PostgreSQL, Keycloak, the sales (Spring Boot), invoicing (Laravel) and ledger
# (Django) APIs, the React app - behind the Caddy gateway, which terminates TLS on the instance:
#
#   https://<host>/            React app          ┐
#   https://<host>/api/<svc>/  the three APIs     ├─ gateway (Caddy) :443, Let's Encrypt -> containers
#   https://<host>/auth/       Keycloak           ┘   only :80/:443 published; :80 redirects
#
# Everything is built into the image (docker compose build + base images pulled), so an
# instance boots straight into `docker compose up` - no registry, npm or Maven access needed
# at boot (Let's Encrypt aside). Secrets are NOT baked: each instance generates its own
# database/Keycloak/app secrets on first boot into /etc/accounting/secrets.env.
#
# Build (the app is private, so tell the builder where to get it - see "Source" below):
#   PROVISION_ENV="APP_SOURCE=s3://<bucket>/accounting/app.tar.gz" INSTANCE_TYPE=t3.large \
#       run.sh ami accounting docker create
#   ENV_TYPE=docker INSTANCE_TYPE=t3.large run.sh instance-ami accounting 1
#
# Then on the instance (run.sh connect / SSM session), point it at your domain:
#   sudo accounting set PUBLIC_HOST=acct.example.com ACME_EMAIL=ops@example.com
# Until then it serves https://<instance-ip>/ with a self-signed certificate.
#
# Needs: 4 GB RAM or more (t3.medium works, t3.large is comfortable) - Keycloak, a JVM API
# and PostgreSQL run side by side; the build itself compiles Java/PHP/JS. Inbound 80/443 from
# anywhere on the instance's security group (Let's Encrypt validates over them), a DNS A
# record -> the instance's Elastic IP, outbound internet while building.
# Targets Amazon Linux 2023 (dnf), x86_64 or arm64.
set -euo pipefail

# --------------------------------------------------
# Settings - override with PROVISION_ENV (manage_ami.sh) or edit here
# --------------------------------------------------

# Where the app comes from:
#   s3://bucket/key.tar.gz   a `git archive` tarball; the builder's instance profile needs
#                            s3:GetObject on it (run.sh ssm create with DEPLOY_ARTIFACT_BUCKET)
#   https://host/owner/repo.git   git; private repos read a token from SSM (APP_GIT_TOKEN_PARAM)
APP_SOURCE="${APP_SOURCE:-https://github.com/zssvaidar/full-stackapps.git}"
APP_REF="${APP_REF:-master}"
# SSM SecureString holding a read-only token for APP_SOURCE (GitHub PAT / Forgejo access token).
# The builder's instance profile needs ssm:GetParameter on it. Never baked into the image.
APP_GIT_TOKEN_PARAM="${APP_GIT_TOKEN_PARAM:-}"

APP_DIR=/opt/accounting/app
STATE_DIR=/var/lib/accounting
CONF_DIR=/etc/accounting
export COMPOSE_PROJECT_NAME=accounting

# Compose v2+ and buildx aren't in Amazon Linux's docker package. Pinned with checksums from
# the releases' checksums.txt - bump both together.
COMPOSE_VERSION=v5.6.0
BUILDX_VERSION=v0.37.2
declare -A COMPOSE_SHA256=(
    [x86_64]=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a
    [aarch64]=733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2
)
declare -A BUILDX_SHA256=(
    [amd64]=982ca20490b45ed1ec8d99795974d3d874a358f75938c9c237305010e6b7e548
    [arm64]=efa38cb7aa7db2dbb9ad049b00b0a9737f66f033626177b5a4e845184ad7ab29
)

# Amazon Linux's own background jobs (dnf-makecache.timer, SSM inventory collection) can grab
# the rpm transaction lock at any point after boot, independent of cloud-init - dnf/yum don't
# wait for that lock, they fail immediately. Retry instead of assuming the box is quiet - see
# ami-scripts/README.md.
retry_pkg() {
    local n=0 max=6
    until "$@"; do
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        echo "package manager busy (rpm lock held) - retry $n/$max in 5s" >&2
        sleep 5
    done
}

log() { echo "docker.sh: $*"; }


# --------------------------------------------------
# Docker engine + compose/buildx plugins
# --------------------------------------------------

retry_pkg dnf install -y docker git jq tar gzip openssl

# Rotate container logs - the default json-file driver grows without bound.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF

arch=$(uname -m)
case "$arch" in
    x86_64)  buildx_arch=amd64 ;;
    aarch64) buildx_arch=arm64 ;;
    *) echo "docker.sh: unsupported architecture $arch" >&2; exit 1 ;;
esac

plugins=/usr/local/lib/docker/cli-plugins
mkdir -p "$plugins"
install_plugin() { # url sha256 target
    curl -fsSL --retry 5 -o "$3.download" "$1"
    echo "$2  $3.download" | sha256sum -c --quiet - || { echo "docker.sh: checksum mismatch for $1" >&2; exit 1; }
    install -m 0755 "$3.download" "$3"
    rm -f "$3.download"
}
install_plugin "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$arch" \
    "${COMPOSE_SHA256[$arch]}" "$plugins/docker-compose"
install_plugin "https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION.linux-$buildx_arch" \
    "${BUILDX_SHA256[$buildx_arch]}" "$plugins/docker-buildx"

systemctl enable --now docker.service
docker compose version
docker buildx version


# --------------------------------------------------
# Source
# --------------------------------------------------

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR" "$STATE_DIR" "$CONF_DIR"
chmod 700 "$CONF_DIR"

case "$APP_SOURCE" in
    s3://*)
        log "fetching $APP_SOURCE"
        aws s3 cp --only-show-errors "$APP_SOURCE" /tmp/app.tar.gz
        tar -xzf /tmp/app.tar.gz -C "$APP_DIR"
        rm -f /tmp/app.tar.gz
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
        git "${git_auth[@]}" clone --quiet --depth 1 --branch "$APP_REF" "$APP_SOURCE" "$APP_DIR" || {
            echo "docker.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "           or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        rm -rf "$APP_DIR/.git"
        ;;
    *) echo "docker.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

[[ -f "$APP_DIR/deploy/compose.public.yml" ]] || { echo "docker.sh: $APP_SOURCE has no deploy/compose.public.yml - wrong repo or ref?" >&2; exit 1; }
echo "$APP_SOURCE @ $APP_REF, built $(date -u +%FT%TZ)" > "$APP_DIR/.source"


# --------------------------------------------------
# On-instance control: /usr/local/bin/accounting (also what systemd runs at boot)
# --------------------------------------------------

cat > /usr/local/bin/accounting <<'SCRIPT'
#!/bin/bash
# Runs the accounting suite with docker compose. Configuration:
#   /etc/accounting/accounting.env   yours: PUBLIC_HOST, ACME_EMAIL, TLS_MODE, ADMIN_ALLOW_CIDRS,
#                                     DEMO_USERS (edit, or use `accounting set`)
#   /etc/accounting/secrets.env      generated once per instance - passwords, keys
#
#   accounting up                  (re)start with the current configuration - systemd runs this
#   accounting set KEY=VALUE ...   change configuration, then restart
#   accounting status | logs [service] | down | credentials | config
set -euo pipefail

APP_DIR=/opt/accounting/app
STATE_DIR=/var/lib/accounting
CONF=/etc/accounting/accounting.env
SECRETS=/etc/accounting/secrets.env
export COMPOSE_PROJECT_NAME=accounting

compose() {
    (cd "$APP_DIR" && docker compose --env-file "$APP_DIR/.env" -f docker-compose.yml -f deploy/compose.public.yml "$@")
}

imds() {
    local token
    token=$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null) || return 1
    curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}

secret() { openssl rand -base64 36 | tr -d '/+=' | cut -c1-32; }

ensure_secrets() {
    [[ -s "$SECRETS" ]] && return
    umask 077
    cat > "$SECRETS" <<EOF
# Generated on first boot of this instance - keep private. Changing a value here after the
# first start does NOT change it inside PostgreSQL/Keycloak.
POSTGRES_PASSWORD=$(secret)
KEYCLOAK_DB_PASSWORD=$(secret)
SALES_DB_PASSWORD=$(secret)
INVOICING_DB_PASSWORD=$(secret)
LEDGER_DB_PASSWORD=$(secret)
KC_ADMIN_USERNAME=admin
KC_ADMIN_PASSWORD=$(secret)
LEDGER_SECRET_KEY=$(secret)$(secret)
INVOICING_APP_KEY=base64:$(openssl rand -base64 32)
DEMO_PASSWORD=$(secret)
EOF
    echo "accounting: generated $SECRETS"
}

render_env() {
    ensure_secrets
    touch "$CONF"
    set -a
    # shellcheck source=/dev/null
    source "$SECRETS"
    # shellcheck source=/dev/null
    source "$CONF"
    set +a

    local is_ip=false
    if [[ -z "${PUBLIC_HOST:-}" ]]; then
        PUBLIC_HOST=$(imds public-ipv4 || imds local-ipv4 || echo localhost)
        echo "accounting: no PUBLIC_HOST set - using $PUBLIC_HOST (set a domain: accounting set PUBLIC_HOST=...)"
    fi
    [[ "$PUBLIC_HOST" =~ ^[0-9.]+$ || "$PUBLIC_HOST" == localhost ]] && is_ip=true

    TLS_MODE="${TLS_MODE:-}"
    if [[ -z "$TLS_MODE" ]]; then
        if $is_ip; then TLS_MODE=internal
        elif [[ -n "${ACME_EMAIL:-}" ]]; then TLS_MODE=acme
        else
            echo "accounting: PUBLIC_HOST is a domain but ACME_EMAIL is unset - using a self-signed certificate for now" >&2
            TLS_MODE=internal
        fi
    fi
    if [[ "$TLS_MODE" == acme ]] && $is_ip; then
        echo "accounting: Let's Encrypt can't issue for $PUBLIC_HOST - using a self-signed certificate" >&2
        TLS_MODE=internal
    fi
    if [[ "$TLS_MODE" == acme && -z "${ACME_EMAIL:-}" ]]; then
        echo "accounting: TLS_MODE=acme needs ACME_EMAIL" >&2; exit 1
    fi

    # Realm imported on Keycloak's first start only: demo users kept (with this instance's own
    # password, not the published one) only if DEMO_USERS=yes.
    local realm_args=()
    [[ "${DEMO_USERS:-no}" == yes ]] && realm_args=(--demo-password "$DEMO_PASSWORD")
    # world-readable: Keycloak's container user (uid 1000) reads it through a bind mount
    (umask 022 && "$APP_DIR/deploy/prepare-realm.py" "$STATE_DIR/realm" "${realm_args[@]}" >/dev/null)

    ADMIN_ALLOW_CIDRS="${ADMIN_ALLOW_CIDRS:-private_ranges}"
    # shellcheck disable=SC2034 # read below through ${!key}
    REALM_IMPORT_DIR="$STATE_DIR/realm"
    local key
    umask 077
    {
        echo "# Rendered by /usr/local/bin/accounting from $SECRETS and $CONF - edit those instead."
        for key in $(grep -oE '^[A-Z_]+' "$SECRETS") PUBLIC_HOST TLS_MODE ACME_EMAIL ADMIN_ALLOW_CIDRS REALM_IMPORT_DIR; do
            printf '%s="%s"\n' "$key" "${!key:-}"
        done
    } > "$APP_DIR/.env"
}

case "${1:-}" in
    up)
        render_env
        compose up -d --no-build --remove-orphans
        compose ps --format 'table {{.Service}}\t{{.Status}}'
        echo "accounting: https://$PUBLIC_HOST/ (TLS: $TLS_MODE)"
        ;;
    set)
        shift
        [[ $# -gt 0 ]] || { echo "usage: accounting set KEY=VALUE ..." >&2; exit 1; }
        touch "$CONF"; chmod 600 "$CONF"
        for pair in "$@"; do
            key=${pair%%=*}
            [[ "$key" =~ ^(PUBLIC_HOST|ACME_EMAIL|TLS_MODE|ADMIN_ALLOW_CIDRS|DEMO_USERS)$ ]] || { echo "accounting: unknown setting $key" >&2; exit 1; }
            sed -i "/^$key=/d" "$CONF"
            printf '%s="%s"\n' "$key" "${pair#*=}" >> "$CONF"
        done
        exec "$0" up
        ;;
    down) compose down ;;
    status) compose ps ;;
    logs) shift; compose logs --tail 200 -f "$@" ;;
    config) cat "$CONF" 2>/dev/null; echo "(secrets: $SECRETS)" ;;
    credentials)
        grep -E '^(KC_ADMIN_USERNAME|KC_ADMIN_PASSWORD|DEMO_PASSWORD)=' "$SECRETS"
        echo "Keycloak admin console: https://<host>/auth/admin/ - only from ADMIN_ALLOW_CIDRS (default: private ranges, e.g. an SSM port-forward)"
        ;;
    *) sed -n '2,12p' "$0"; exit 1 ;;
esac
SCRIPT
chmod 755 /usr/local/bin/accounting

cat > /etc/systemd/system/accounting.service <<'EOF'
[Unit]
Description=Accounting suite (docker compose: Caddy gateway, APIs, Keycloak, PostgreSQL)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/accounting up
ExecStop=/usr/local/bin/accounting down
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable accounting.service


# --------------------------------------------------
# Build every image now, so instances boot without building anything
# --------------------------------------------------

log "building images (Java, PHP, Python, React - takes a while)"
(cd "$APP_DIR" && PUBLIC_HOST=build.invalid docker compose -f docker-compose.yml -f deploy/compose.public.yml build --pull)
(cd "$APP_DIR" && PUBLIC_HOST=build.invalid docker compose -f docker-compose.yml -f deploy/compose.public.yml pull --ignore-buildable --quiet)


# --------------------------------------------------
# Smoke test the real thing before it becomes an image: start the stack exactly as an
# instance would (self-signed TLS on localhost), sign in against Keycloak and call an API
# through Caddy. Then remove every trace - containers, volumes, secrets, certificates - so
# each instance starts from an empty database and generates its own secrets.
# --------------------------------------------------

cleanup_smoke() {
    /usr/local/bin/accounting down >/dev/null 2>&1 || true
    (cd "$APP_DIR" && PUBLIC_HOST=x docker compose -f docker-compose.yml -f deploy/compose.public.yml down --volumes --remove-orphans >/dev/null 2>&1) || true
    rm -rf "${CONF_DIR:?}"/* "${STATE_DIR:?}"/* "$APP_DIR/.env"
}
trap cleanup_smoke EXIT

printf 'PUBLIC_HOST=localhost\nTLS_MODE=internal\nDEMO_USERS=yes\n' > "$CONF_DIR/accounting.env"
/usr/local/bin/accounting up

log "waiting for the stack to answer through Caddy"
ok=false
for _ in $(seq 1 90); do
    if curl -fsk -o /dev/null https://localhost/auth/realms/accounting/.well-known/openid-configuration \
        && curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/sales/me | grep -q 401 \
        && curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/invoicing/me | grep -q 401 \
        && curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/ledger/me | grep -q 401; then
        ok=true; break
    fi
    sleep 5
done
$ok || { /usr/local/bin/accounting status; echo "docker.sh: smoke test failed - stack not answering through Caddy" >&2; exit 1; }

curl -fsS -o /dev/null -w '%{http_code}' http://localhost/ | grep -q 308 || { echo "docker.sh: smoke test failed - :80 doesn't redirect to HTTPS" >&2; exit 1; }
curl -fsk https://localhost/ | grep -q '<div id="root">' || { echo "docker.sh: smoke test failed - React app not served" >&2; exit 1; }

issuer=$(curl -fsk https://localhost/auth/realms/accounting/.well-known/openid-configuration | jq -r .issuer)
[[ "$issuer" == "https://localhost/auth/realms/accounting" ]] || { echo "docker.sh: smoke test failed - issuer is $issuer" >&2; exit 1; }

demo_password=$(grep '^DEMO_PASSWORD=' "$CONF_DIR/secrets.env" | cut -d= -f2-)
token=$(curl -fsk https://localhost/auth/realms/accounting/protocol/openid-connect/token \
    -d grant_type=password -d client_id=accounting-web -d username=alice --data-urlencode "password=$demo_password" | jq -r .access_token)
for svc in sales invoicing ledger; do
    who=$(curl -fsk -H "Authorization: Bearer $token" "https://localhost/api/$svc/me" | jq -r .username)
    [[ "$who" == alice ]] || { echo "docker.sh: smoke test failed - /api/$svc/me with a token returned '$who'" >&2; exit 1; }
done

log "smoke test passed - app, APIs and Keycloak answer over HTTPS through Caddy; tokens accepted by all three APIs"
