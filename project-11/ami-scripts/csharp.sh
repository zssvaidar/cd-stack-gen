#!/bin/bash
# project-14's ASP.NET Core app (project-14/csharp-app) run directly on the instance: Caddy on
# :80 -> Kestrel on 127.0.0.1:8080 as a systemd service, smoke-tested through Caddy before
# snapshot. Same shape as nodejs_caddy.sh. The container version of the same app is
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

retry_pkg dnf install -y libicu git tar

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
# Caddy: :80 -> 127.0.0.1:8080. Access log (JSON) to the journal for Loki, health probes left out.
# /metrics answers 404 here - it's for Alloy on loopback only.
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
    *) echo "csharp.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

caddy_tgz=$(mktemp)
curl -fsSL --retry 5 -o "$caddy_tgz" \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz"
echo "${CADDY_SHA512[$caddy_arch]}  $caddy_tgz" | sha512sum -c --quiet - \
    || { echo "csharp.sh: checksum mismatch for caddy $CADDY_VERSION" >&2; exit 1; }
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
	# access log (JSON) to stderr -> journal (caddy.service) -> Alloy -> Loki; probes left out
	log
	log_skip /health*

	# Prometheus metrics are for Alloy on loopback only
	respond /metrics 404

	reverse_proxy 127.0.0.1:$APP_PORT
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
# Monitoring: Grafana Alloy ships host metrics, the app's metrics, a health probe and the journal
# of these units to the monitoring host (grafana.sh). Off until /etc/alloy/endpoint.env exists -
# see project-14/monitoring/alloy/install.sh.
# --------------------------------------------------

export APP_NAME
APP_METRICS_ADDR=127.0.0.1:$APP_PORT APP_METRICS_PATH=/metrics \
APP_HEALTH_URL=http://127.0.0.1/health/ready \
LOG_UNITS="$APP_NAME.service|caddy.service" \
    bash "$SRC/$MONITORING_SUBDIR/alloy/install.sh"


# --------------------------------------------------
# Drop the SDK and sources - the self-contained publish carries its own runtime.
# --------------------------------------------------

rm -rf /tmp/dotnet /tmp/dotnet-install.sh
rm -rf "$SRC" /tmp/dotnet-home /tmp/nuget


# --------------------------------------------------
# Smoke test through Caddy before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start $APP_NAME.service
systemctl restart caddy.service

for _ in $(seq 60); do
    curl -fsS http://127.0.0.1/health/ready 2>/dev/null | grep -q '"status":"UP"' && break
    sleep 1
done

curl -fsS http://127.0.0.1:$APP_PORT/metrics | grep -q '^# HELP' \
    || { echo "csharp.sh: smoke test failed - no Prometheus metrics on 127.0.0.1:$APP_PORT/metrics" >&2; exit 1; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/metrics)" == 404 ]] \
    || { echo "csharp.sh: smoke test failed - /metrics is reachable through Caddy" >&2; exit 1; }

curl -fsS http://127.0.0.1/health/ready | grep -q '"status":"UP"' \
    && echo "csharp.sh: smoke test passed - app reachable through Caddy" \
    || { echo "csharp.sh: smoke test failed - app not reachable through Caddy" >&2; journalctl -u $APP_NAME -u caddy --no-pager -n 50 >&2; exit 1; }
