#!/bin/bash
# Monitoring host for project-14's apps: Grafana + Mimir (metrics) + Loki (logs) on one instance,
# everything from Grafana's signed rpm repo. The app images (laravel/spring/csharp/go.sh) run
# Grafana Alloy, which pushes to this host once it's told where it is:
#
#   app instance (Alloy) --remote-write :9009--> Mimir ─┐
#                        --push         :3100--> Loki  ─┴─> Grafana :3000 (dashboards, explore)
#
# Configs come from the repo, not heredocs: project-14/monitoring/{mimir,loki,grafana,alloy}.
# Grafana gets both data sources and the "project-14 apps" dashboard provisioned. This host runs
# Alloy too, for its own metrics and logs (app="monitoring").
#
# Build:
#   INSTANCE_TYPE=t3.medium run.sh ami monitoring grafana create
#   PROVISION_ENV="APP_REF=my-branch" run.sh ami monitoring grafana create
#
# Launch one per environment. In the app instances' user-data, write /etc/alloy/endpoint.env:
#   MONITORING_HOST=<this instance's private IP or DNS name>
#   ENVIRONMENT=dev
# (or run `sudo alloy-endpoint <ip> dev` on each of them later).
#
# Security group: inbound 9009 and 3100 from the VPC (app instances' Alloy) - Mimir and Loki have
# NO authentication here, so never open them wider. Inbound 3000 for Grafana from wherever
# you'll reach it (an ALB, the egress-balancer, your IP, or none and use an SSM port forward).
#
# Admin login is generated per instance, never baked: on first boot grafana-init writes a random
# password to /etc/grafana/admin.env (`sudo cat` it over SSM). user-data can write
# GF_SECURITY_ADMIN_PASSWORD=... there first to choose it. Grafana only applies it when it creates
# its database on first start - change it later with `grafana cli admin reset-admin-password`.
#
# Sizing: 4 GB RAM (t3.medium) for Mimir + Loki + Grafana side by side; give the root volume room
# for 30 days of metrics and 14 days of logs (/var/lib/mimir, /var/lib/loki). Needs outbound
# internet while building (rpm.grafana.com, git). Targets Amazon Linux 2023 (dnf), x86_64 or arm64.
set -euo pipefail

# --------------------------------------------------
# Settings - override with PROVISION_ENV (manage_ami.sh) or edit here
# --------------------------------------------------

# Where the configs come from (same options as the app scripts):
#   s3://bucket/key.tar.gz        a `git archive` tarball of this repo
#   https://host/owner/repo.git   git; private repos read a token from SSM (APP_GIT_TOKEN_PARAM)
APP_SOURCE="${APP_SOURCE:-https://github.com/zssvaidar/cd-stack-gen.git}"
APP_REF="${APP_REF:-master}"
APP_GIT_TOKEN_PARAM="${APP_GIT_TOKEN_PARAM:-}"
MONITORING_SUBDIR="${MONITORING_SUBDIR:-project-14/monitoring}"

log() { echo "grafana.sh: $*"; }

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

wait_for() { # wait_for <seconds> <description> <command...>
    local secs=$1 what=$2; shift 2
    for _ in $(seq "$secs"); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "grafana.sh: timed out after ${secs}s waiting for $what" >&2
    return 1
}


# --------------------------------------------------
# Packages. The grafana, mimir and loki packages start their services on install, with default
# configs - stop them straight away and throw away what they wrote (Grafana's database would
# otherwise keep the default admin/admin login).
# --------------------------------------------------

cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

retry_pkg dnf install -y grafana mimir loki git tar

systemctl stop grafana-server.service mimir.service loki.service 2>/dev/null || true
rm -rf /var/lib/grafana/grafana.db* /var/lib/mimir/* /tmp/loki


# --------------------------------------------------
# Source (configs only)
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
            echo "grafana.sh: could not clone $APP_SOURCE - a private repo needs APP_GIT_TOKEN_PARAM," >&2
            echo "            or build from a tarball: APP_SOURCE=s3://<bucket>/<key>.tar.gz" >&2
            exit 1
        }
        unset git_auth
        ;;
    *) echo "grafana.sh: APP_SOURCE must be an s3:// or https:// URL" >&2; exit 1 ;;
esac

MON="$SRC/$MONITORING_SUBDIR"
[[ -f "$MON/mimir/config.yml" ]] || { echo "grafana.sh: no $MONITORING_SUBDIR/mimir/config.yml in $APP_SOURCE - wrong repo, ref or MONITORING_SUBDIR?" >&2; exit 1; }


# --------------------------------------------------
# Mimir: metrics, :9009. Data in /var/lib/mimir (the package's home for the mimir user).
# --------------------------------------------------

install -m 0640 -o root -g mimir "$MON/mimir/config.yml" /etc/mimir/config.yml
install -d -m 0755 -o mimir -g mimir /var/lib/mimir


# --------------------------------------------------
# Loki: logs, :3100. Data in /var/lib/loki, not the package default /tmp/loki.
# --------------------------------------------------

loki_group=$(id -gn loki)
install -m 0640 -o root -g "$loki_group" "$MON/loki/config.yml" /etc/loki/config.yml
install -d -m 0750 -o loki -g "$loki_group" /var/lib/loki
mkdir -p /etc/systemd/system/loki.service.d
cat > /etc/systemd/system/loki.service.d/project-14.conf <<'EOF'
[Service]
WorkingDirectory=/var/lib/loki
EOF


# --------------------------------------------------
# Grafana: :3000, data sources + dashboards provisioned from the repo, read-only in the UI.
# --------------------------------------------------

install -d -m 0750 -o root -g grafana /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /etc/grafana/dashboards
install -m 0640 -o root -g grafana "$MON"/grafana/provisioning/datasources/*.yaml /etc/grafana/provisioning/datasources/
install -m 0640 -o root -g grafana "$MON"/grafana/provisioning/dashboards/*.yaml /etc/grafana/provisioning/dashboards/
install -m 0640 -o root -g grafana "$MON"/grafana/dashboards/*.json /etc/grafana/dashboards/

cat > /usr/local/sbin/grafana-init.sh <<'EOF'
#!/bin/bash
# First boot: generate this instance's Grafana admin password, unless user-data already set one.
set -euo pipefail
ENV_FILE=/etc/grafana/admin.env
if ! grep -qs '^GF_SECURITY_ADMIN_PASSWORD=.' "$ENV_FILE"; then
    echo "GF_SECURITY_ADMIN_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)" >> "$ENV_FILE"
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"
EOF
chmod 0755 /usr/local/sbin/grafana-init.sh

cat > /etc/systemd/system/grafana-init.service <<'EOF'
[Unit]
Description=Grafana admin password for this instance
# user-data (write_files) runs in cloud-init.service - let it write admin.env first
After=cloud-init.service
Before=grafana-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/grafana-init.sh

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/project-14.conf <<'EOF'
[Unit]
Requires=grafana-init.service
After=grafana-init.service mimir.service loki.service

[Service]
EnvironmentFile=/etc/grafana/admin.env
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
Environment=GF_PLUGINS_PREINSTALL_DISABLED=true
Environment=GF_LOG_MODE=console
EOF


# --------------------------------------------------
# Alloy on this host too: its own metrics/logs, straight to localhost.
# --------------------------------------------------

APP_NAME=monitoring APP_METRICS_ADDR=127.0.0.1:9009 APP_METRICS_PATH=/metrics \
APP_HEALTH_URL=http://127.0.0.1:3000/api/health \
LOG_UNITS="grafana-server.service|mimir.service|loki.service|alloy.service" \
MONITORING_HOST=127.0.0.1 \
    bash "$MON/alloy/install.sh"

systemctl daemon-reload
systemctl enable mimir.service loki.service grafana-init.service grafana-server.service alloy.service

rm -rf "$SRC"


# --------------------------------------------------
# Smoke test: all four up, Grafana's data sources healthy, and this host's own metrics and logs
# arriving through Alloy -> Mimir/Loki. Then wipe every bit of state the test created
# (metrics, logs, Grafana's database with its admin user, the password) so each instance
# starts empty.
# --------------------------------------------------

ok=true
systemctl start mimir.service loki.service || ok=false
wait_for 180 "mimir" curl -fsS http://127.0.0.1:9009/ready || ok=false
wait_for 180 "loki" curl -fsS http://127.0.0.1:3100/ready || ok=false
systemctl start grafana-init.service grafana-server.service alloy.service || ok=false
wait_for 120 "grafana" curl -fsS http://127.0.0.1:3000/api/health || ok=false

if [[ "$ok" == "true" ]]; then
    pw=$(sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p' /etc/grafana/admin.env)
    for ds in mimir loki; do
        curl -fsS -u "admin:$pw" "http://127.0.0.1:3000/api/datasources/uid/$ds/health" | grep -q '"status":"OK"' \
            || { echo "grafana.sh: data source $ds not healthy" >&2; ok=false; }
    done
    curl -fsS -u "admin:$pw" http://127.0.0.1:3000/api/dashboards/uid/project-14-apps >/dev/null \
        || { echo "grafana.sh: dashboard project-14-apps not provisioned" >&2; ok=false; }
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -u admin:admin http://127.0.0.1:3000/api/org)" == 401 ]] \
        || { echo "grafana.sh: default admin/admin login still works" >&2; ok=false; }
    unset pw
    wait_for 120 "Alloy's metrics in Mimir" sh -c \
        "curl -fsS -G http://127.0.0.1:9009/prometheus/api/v1/query --data-urlencode 'query=probe_success{app=\"monitoring\"} == 1' | grep -q '\"result\":\[{'" \
        || ok=false
    wait_for 120 "Alloy's logs in Loki" sh -c \
        "curl -fsS -G http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode 'query={app=\"monitoring\"}' --data-urlencode limit=1 | grep -q '\"values\":\[\['" \
        || ok=false
fi

if [[ "$ok" != "true" ]]; then
    echo "grafana.sh: smoke test failed" >&2
    journalctl -u mimir -u loki -u grafana-server -u alloy --no-pager -n 80 >&2 || true
    exit 1
fi
echo "grafana.sh: smoke test passed - Mimir, Loki, Grafana and Alloy working together"

systemctl stop alloy.service grafana-server.service grafana-init.service loki.service mimir.service
rm -rf /var/lib/mimir/* /var/lib/loki/* /var/lib/alloy/data/* /var/lib/grafana/grafana.db*
rm -f /etc/grafana/admin.env
