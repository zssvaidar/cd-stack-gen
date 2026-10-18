#!/bin/bash
# Installs Grafana Alloy (from Grafana's signed rpm repo) with config.alloy next to this file.
# Run as root by the AMI scripts in project-11/ami-scripts (laravel/spring/csharp/go/grafana.sh)
# while baking, from the repo checkout they already fetched. Amazon Linux 2023 (dnf).
#
# Describe the app with environment variables (baked into /etc/alloy/app.env):
#   APP_NAME           label on everything this instance sends, e.g. go-app
#   APP_METRICS_ADDR   host:port of the app's Prometheus endpoint, e.g. 127.0.0.1:8080
#   APP_METRICS_PATH   its path, e.g. /metrics
#   APP_HEALTH_URL     URL the blackbox probe checks, e.g. http://127.0.0.1/health/ready
#   LOG_UNITS          regex of systemd units whose journal is shipped, e.g. "go-app.service|caddy.service"
#
# Where to send it is decided at launch, not bake time: alloy.service only starts once
# /etc/alloy/endpoint.env exists. Write it from user-data:
#   MONITORING_HOST=10.10.1.23      # private IP / DNS name of the grafana.sh instance
#   ENVIRONMENT=dev                 # optional "env" label
# or on a running instance:  sudo alloy-endpoint 10.10.1.23 dev
# Set MONITORING_HOST (and ENVIRONMENT) here to write it at bake time instead - grafana.sh
# does, pointing at itself.
set -euo pipefail

: "${APP_NAME:?}" "${APP_METRICS_ADDR:?}" "${APP_METRICS_PATH:?}" "${APP_HEALTH_URL:?}" "${LOG_UNITS:?}"
MONITORING_HOST="${MONITORING_HOST:-}"
ENVIRONMENT="${ENVIRONMENT:-}"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
log() { echo "alloy/install.sh: $*"; }

# See ami-scripts/README.md: Amazon Linux's background jobs can hold the rpm lock at any time.
retry_pkg() {
    local n=0 max=6
    until "$@"; do
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        echo "package manager busy (rpm lock held) - retry $n/$max in 5s" >&2
        sleep 5
    done
}

if [[ ! -f /etc/yum.repos.d/grafana.repo ]]; then
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
fi

log "installing alloy"
retry_pkg dnf install -y alloy

install -m 0640 -o root -g alloy "$here/config.alloy" /etc/alloy/config.alloy

cat > /etc/alloy/app.env <<EOF
APP_NAME=$APP_NAME
APP_METRICS_ADDR=$APP_METRICS_ADDR
APP_METRICS_PATH=$APP_METRICS_PATH
APP_HEALTH_URL=$APP_HEALTH_URL
LOG_UNITS="$LOG_UNITS"
EOF
chmod 0644 /etc/alloy/app.env

mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/project-14.conf <<'EOF'
[Unit]
# user-data (write_files) runs in cloud-init.service - let it write endpoint.env first
After=cloud-init.service
# Off until someone says where the monitoring host is
ConditionPathExists=/etc/alloy/endpoint.env

[Service]
EnvironmentFile=/etc/alloy/app.env
EnvironmentFile=/etc/alloy/endpoint.env
EOF

cat > /usr/local/sbin/alloy-endpoint <<'EOF'
#!/bin/bash
# alloy-endpoint <monitoring-host> [environment] - point Alloy at the monitoring host and (re)start it
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: alloy-endpoint <monitoring-host> [environment]" >&2; exit 1; }
{
    echo "MONITORING_HOST=$1"
    [[ -n "${2:-}" ]] && echo "ENVIRONMENT=$2"
} > /etc/alloy/endpoint.env
systemctl restart alloy.service
systemctl --no-pager --lines=0 status alloy.service
EOF
chmod 0755 /usr/local/sbin/alloy-endpoint

if [[ -n "$MONITORING_HOST" ]]; then
    {
        echo "MONITORING_HOST=$MONITORING_HOST"
        [[ -n "$ENVIRONMENT" ]] && echo "ENVIRONMENT=$ENVIRONMENT"
    } > /etc/alloy/endpoint.env
fi

# Syntax and component arguments, without starting anything. sys.env() values are only read at run time.
alloy validate /etc/alloy/config.alloy

systemctl daemon-reload
systemctl enable alloy.service
log "alloy installed for $APP_NAME ($([[ -n "$MONITORING_HOST" ]] && echo "sending to $MONITORING_HOST" || echo "off until /etc/alloy/endpoint.env exists"))"
