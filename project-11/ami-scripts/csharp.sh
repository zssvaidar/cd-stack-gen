#!/bin/bash
# project-14's ASP.NET Core app (project-14/csharp-app) run directly on the instance: nginx on
# :80 -> Kestrel on 127.0.0.1:8080 as a systemd service, smoke-tested through nginx before
# snapshot. Same shape as nodejs.sh. The container version of the same app is
# project-14/csharp-app/Dockerfile.
#
# Published self-contained on the builder (the .NET runtime ships inside the app directory),
# and the SDK deleted again - no .NET install on the instance, nothing for dnf to update under
# it. The SDK comes from Microsoft's dotnet-install.sh because Amazon Linux's repos lag behind
# current .NET. Health: /health (liveness), /health/ready (readiness) - point an ALB target
# group at /health/ready.
#
# Build:
#   run.sh ami csharp-app csharp create
#   PROVISION_ENV="APP_REF=my-branch" run.sh ami csharp-app csharp create
#   PROVISION_ENV="APP_GIT_TOKEN_PARAM=/cd-stack-gen/git-token" run.sh ami csharp-app csharp create   # private repo
#
# Needs outbound internet while building (dnf, git, dot.net, nuget.org). Inbound :80 on the
# instance's security group. Targets Amazon Linux 2023 (dnf), x86_64 or arm64.
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
# Shared Grafana Alloy setup inside APP_SOURCE (see "Monitoring" below).
MONITORING_SUBDIR="${MONITORING_SUBDIR:-project-14/monitoring}"
# The app's directory inside APP_SOURCE.
APP_SUBDIR="${APP_SUBDIR:-project-14/csharp-app}"

APP_NAME=csharp-app
APP_DIR=/opt/$APP_NAME
APP_PORT=8080

log() { echo "csharp.sh: $*"; }

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
# Packages. libicu for .NET globalization; the SDK itself is installed below, build-only.
# --------------------------------------------------

retry_pkg dnf install -y libicu git nginx tar

# --------------------------------------------------
# Source
# --------------------------------------------------

SRC=/tmp/app-src
rm -rf "$SRC"
mkdir -p "$SRC"

case "$APP_SOURCE" in
    s3://*)
        log "fetching $APP_SOURCE"
        aws s3 cp --only-show-errors "$APP_SOURCE" /tmp/app.tar.gz
        tar -xzf /tmp/app.tar.gz -C "$SRC"
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
        git "${git_auth[@]}" clone --quiet --depth 1 --branch "$APP_REF" "$APP_SOURCE" "$SRC" || {
            echo "csharp.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "           or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        ;;
    *) echo "csharp.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

[[ -f "$SRC/$APP_SUBDIR/CsharpApp.csproj" ]] || { echo "csharp.sh: no $APP_SUBDIR/CsharpApp.csproj in $APP_SOURCE - wrong repo, ref or APP_SUBDIR?" >&2; exit 1; }


# --------------------------------------------------
# Build: SDK into /tmp (build-only), publish self-contained for this CPU.
# --------------------------------------------------

DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
case "$(uname -m)" in
    x86_64)  RID=linux-x64 ;;
    aarch64) RID=linux-arm64 ;;
    *) echo "csharp.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

log "installing .NET SDK $DOTNET_CHANNEL (build only)"
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir /tmp/dotnet

log "building $APP_SUBDIR for $RID"
mkdir -p "$APP_DIR"
(
    cd "$SRC/$APP_SUBDIR"
    export DOTNET_ROOT=/tmp/dotnet PATH=/tmp/dotnet:$PATH HOME=/tmp/dotnet-home \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 NUGET_PACKAGES=/tmp/nuget
    dotnet publish -c Release -r "$RID" --self-contained true -o "$APP_DIR"
)
echo "$APP_SOURCE @ $APP_REF ($APP_SUBDIR), built $(date -u +%FT%TZ)" > "$APP_DIR/.source"

useradd --system --no-create-home --shell /sbin/nologin csharpapp 2>/dev/null || true

cat > /etc/systemd/system/$APP_NAME.service <<EOF
[Unit]
Description=project-14 csharp-app
After=network.target

[Service]
Type=simple
User=csharpapp
Group=csharpapp
ExecStart=$APP_DIR/CsharpApp
WorkingDirectory=$APP_DIR
Environment=HOST=127.0.0.1
Environment=PORT=$APP_PORT
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
# Optional overrides (written by user-data, not baked)
EnvironmentFile=-/etc/$APP_NAME/app.env
Restart=on-failure
RestartSec=2
# ASP.NET Core drains for up to 30s on SIGTERM by default
TimeoutStopSec=35
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $APP_NAME.service


# --------------------------------------------------
# nginx: :80 -> 127.0.0.1:8080. Access log to the journal too (for Loki), health probes kept
# out of both. /metrics is for Alloy on loopback only.
# --------------------------------------------------

cat > /etc/nginx/conf.d/app.conf <<EOF
server {
    listen 80 default_server;
    server_name _;

    access_log /var/log/nginx/access.log combined;
    access_log syslog:server=unix:/dev/log,tag=nginx,nohostname combined;

    location /health {
        access_log off;
        proxy_pass http://127.0.0.1:$APP_PORT;
    }

    location = /metrics {
        return 404;
    }

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

nginx -t
systemctl enable nginx.service


# --------------------------------------------------
# Monitoring: Grafana Alloy ships host metrics, the app's metrics, a health probe and the journal
# of these units to the monitoring host (grafana.sh). Off until /etc/alloy/endpoint.env exists -
# see project-14/monitoring/alloy/install.sh.
# --------------------------------------------------

export APP_NAME
APP_METRICS_ADDR=127.0.0.1:$APP_PORT APP_METRICS_PATH=/metrics \
APP_HEALTH_URL=http://127.0.0.1/health/ready \
LOG_UNITS="$APP_NAME.service|nginx.service" \
    bash "$SRC/$MONITORING_SUBDIR/alloy/install.sh"


# --------------------------------------------------
# Drop the SDK and sources - the self-contained publish carries its own runtime.
# --------------------------------------------------

rm -rf /tmp/dotnet /tmp/dotnet-install.sh
rm -rf "$SRC" /tmp/dotnet-home /tmp/nuget


# --------------------------------------------------
# Smoke test through nginx before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start $APP_NAME.service
systemctl restart nginx.service

for _ in $(seq 60); do
    curl -fsS http://127.0.0.1/health/ready 2>/dev/null | grep -q '"status":"UP"' && break
    sleep 1
done

curl -fsS http://127.0.0.1:$APP_PORT/metrics | grep -q '^# HELP' \
    || { echo "csharp.sh: smoke test failed - no Prometheus metrics on 127.0.0.1:$APP_PORT/metrics" >&2; exit 1; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/metrics)" == 404 ]] \
    || { echo "csharp.sh: smoke test failed - /metrics is reachable through nginx" >&2; exit 1; }

curl -fsS http://127.0.0.1/health/ready | grep -q '"status":"UP"' \
    && echo "csharp.sh: smoke test passed - app reachable through nginx" \
    || { echo "csharp.sh: smoke test failed - app not reachable through nginx" >&2; journalctl -u $APP_NAME --no-pager -n 50 >&2; exit 1; }
