#!/bin/bash
# project-14's Go app (project-14/go-app) run directly on the instance: nginx on :80 -> the Go
# binary on 127.0.0.1:8080 as a systemd service, smoke-tested through nginx before snapshot.
# Same shape as nodejs.sh. The container version of the same app is project-14/go-app/Dockerfile.
#
# The binary is compiled on the builder and the Go toolchain removed again, so the image only
# carries the static binary. Health: /health (liveness), /health/ready (readiness, 503 while
# draining on shutdown) - point an ALB target group at /health/ready.
#
# Build:
#   run.sh ami go-app go create
#   PROVISION_ENV="APP_REF=my-branch" run.sh ami go-app go create
#   PROVISION_ENV="APP_GIT_TOKEN_PARAM=/cd-stack-gen/git-token" run.sh ami go-app go create   # private repo
#
# Needs outbound internet while building (dnf, git, proxy.golang.org). Inbound :80 on the
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
# The app's directory inside APP_SOURCE.
APP_SUBDIR="${APP_SUBDIR:-project-14/go-app}"

APP_NAME=go-app
APP_DIR=/opt/$APP_NAME
APP_PORT=8080

log() { echo "go.sh: $*"; }

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
# Packages. golang only for the build - removed again below.
# --------------------------------------------------

retry_pkg dnf install -y golang git nginx tar


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
            echo "go.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "       or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        ;;
    *) echo "go.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

[[ -f "$SRC/$APP_SUBDIR/go.mod" ]] || { echo "go.sh: no $APP_SUBDIR/go.mod in $APP_SOURCE - wrong repo, ref or APP_SUBDIR?" >&2; exit 1; }


# --------------------------------------------------
# Build. GOTOOLCHAIN=auto: if Amazon Linux's golang is older than go.mod asks for, go fetches
# the right toolchain from proxy.golang.org. Caches go to /tmp, not root's home.
# --------------------------------------------------

log "building $APP_SUBDIR"
mkdir -p "$APP_DIR"
(
    cd "$SRC/$APP_SUBDIR"
    export GOTOOLCHAIN=auto GOPATH=/tmp/gopath GOCACHE=/tmp/gocache CGO_ENABLED=0
    go test ./...
    go build -trimpath -ldflags="-s -w" -o "$APP_DIR/$APP_NAME" .
)
echo "$APP_SOURCE @ $APP_REF ($APP_SUBDIR), built $(date -u +%FT%TZ)" > "$APP_DIR/.source"

useradd --system --no-create-home --shell /sbin/nologin goapp 2>/dev/null || true

cat > /etc/systemd/system/$APP_NAME.service <<EOF
[Unit]
Description=project-14 Go app
After=network.target

[Service]
Type=simple
User=goapp
Group=goapp
ExecStart=$APP_DIR/$APP_NAME
Environment=HOST=127.0.0.1
Environment=PORT=$APP_PORT
# Optional overrides (written by user-data, not baked)
EnvironmentFile=-/etc/$APP_NAME/app.env
Restart=on-failure
RestartSec=2
# The app drains in-flight requests for up to 20s on SIGTERM
TimeoutStopSec=25
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
# nginx: :80 -> 127.0.0.1:8080. Health probes kept out of the access log.
# --------------------------------------------------

cat > /etc/nginx/conf.d/app.conf <<EOF
server {
    listen 80 default_server;
    server_name _;

    location /health {
        access_log off;
        proxy_pass http://127.0.0.1:$APP_PORT;
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
# Drop the build toolchain and sources - the image only needs the binary.
# --------------------------------------------------

retry_pkg dnf remove -y golang
rm -rf "$SRC" /tmp/gopath /tmp/gocache


# --------------------------------------------------
# Smoke test through nginx before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start $APP_NAME.service
systemctl restart nginx.service

for _ in $(seq 15); do
    curl -fsS http://127.0.0.1/health/ready 2>/dev/null | grep -q '"status":"UP"' && break
    sleep 1
done

curl -fsS http://127.0.0.1/health/ready | grep -q '"status":"UP"' \
    && echo "go.sh: smoke test passed - app reachable through nginx" \
    || { echo "go.sh: smoke test failed - app not reachable through nginx" >&2; journalctl -u $APP_NAME --no-pager -n 50 >&2; exit 1; }
