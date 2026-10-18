#!/bin/bash
# project-14's Spring Boot app (project-14/spring-app) run directly on the instance: nginx on :80
# -> the JVM on 127.0.0.1:8080 as a systemd service, smoke-tested through nginx before snapshot.
# Same shape as nodejs.sh. The container version of the same app is project-14/spring-app/Dockerfile.
#
# The jar is built on the builder with the project's Maven wrapper (tests included); the JDK is
# swapped for the headless JRE afterwards. Health: /actuator/health,
# /actuator/health/liveness, /actuator/health/readiness - point an ALB target group at the last.
#
# Build:
#   run.sh ami spring-app spring create
#   PROVISION_ENV="APP_REF=my-branch" run.sh ami spring-app spring create
#   PROVISION_ENV="APP_GIT_TOKEN_PARAM=/cd-stack-gen/git-token" run.sh ami spring-app spring create   # private repo
#
# Needs outbound internet while building (dnf, git, Maven Central). Inbound :80 on the
# instance's security group. 1 GB RAM is enough to run it (t3.micro); building is faster on 2 GB+.
# Targets Amazon Linux 2023 (dnf), x86_64 or arm64.
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
APP_SUBDIR="${APP_SUBDIR:-project-14/spring-app}"

APP_NAME=spring-app
APP_DIR=/opt/$APP_NAME
APP_PORT=8080

log() { echo "spring.sh: $*"; }

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
# Packages. Corretto 21: JDK for the build, swapped for the headless JRE below.
# --------------------------------------------------

retry_pkg dnf install -y java-21-amazon-corretto-devel java-21-amazon-corretto-headless git nginx tar

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
            echo "spring.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "           or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        ;;
    *) echo "spring.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

[[ -f "$SRC/$APP_SUBDIR/pom.xml" ]] || { echo "spring.sh: no $APP_SUBDIR/pom.xml in $APP_SOURCE - wrong repo, ref or APP_SUBDIR?" >&2; exit 1; }


# --------------------------------------------------
# Build with the project's Maven wrapper (downloads Maven itself). Caches go to /tmp, not
# root's home.
# --------------------------------------------------

log "building $APP_SUBDIR"
mkdir -p "$APP_DIR"
(
    cd "$SRC/$APP_SUBDIR"
    export MAVEN_USER_HOME=/tmp/m2
    sh ./mvnw -B -q -Dmaven.repo.local=/tmp/m2/repository package
    cp target/*.jar "$APP_DIR/$APP_NAME.jar"
)
echo "$APP_SOURCE @ $APP_REF ($APP_SUBDIR), built $(date -u +%FT%TZ)" > "$APP_DIR/.source"

useradd --system --no-create-home --shell /sbin/nologin springapp 2>/dev/null || true

cat > /etc/systemd/system/$APP_NAME.service <<EOF
[Unit]
Description=project-14 spring-app
After=network.target

[Service]
Type=simple
User=springapp
Group=springapp
ExecStart=/usr/bin/java \$JAVA_OPTS -jar $APP_DIR/$APP_NAME.jar
Environment="JAVA_OPTS=-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
Environment=SERVER_ADDRESS=127.0.0.1
Environment=PORT=$APP_PORT
# Optional overrides (written by user-data, not baked)
EnvironmentFile=-/etc/$APP_NAME/app.env
Restart=on-failure
RestartSec=2
# server.shutdown=graceful waits up to 30s for in-flight requests
TimeoutStopSec=35
SuccessExitStatus=143
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
# Drop the build toolchain and sources - the image only needs the jar and a JRE.
# --------------------------------------------------

retry_pkg dnf remove -y java-21-amazon-corretto-devel
java -version 2>&1 | head -1   # the headless JRE still provides /usr/bin/java
rm -rf "$SRC" /tmp/m2


# --------------------------------------------------
# Smoke test through nginx before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start $APP_NAME.service
systemctl restart nginx.service

for _ in $(seq 60); do
    curl -fsS http://127.0.0.1/actuator/health/readiness 2>/dev/null | grep -q '"status":"UP"' && break
    sleep 1
done

curl -fsS http://127.0.0.1/actuator/health/readiness | grep -q '"status":"UP"' \
    && echo "spring.sh: smoke test passed - app reachable through nginx" \
    || { echo "spring.sh: smoke test failed - app not reachable through nginx" >&2; journalctl -u $APP_NAME --no-pager -n 50 >&2; exit 1; }
