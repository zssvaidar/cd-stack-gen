#!/usr/bin/env bash
# deploy.sh <server> [host]
#   server: nginx | apache   - which front end to run in front of php-fpm
#   host:   optional SSH target (user@host); omitted = deploy on this machine
#
# Every step checks current state before acting - this is meant to be safe
# to run repeatedly (a Jenkins job re-run, a flaky deploy retried) without
# doing extra work or causing extra downtime.
#
#   ./scripts/deploy.sh nginx                 # deploy locally
#   ./scripts/deploy.sh apache ec2-user@10.0.1.23   # deploy over SSH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/idempotent.sh
source "$SCRIPT_DIR/lib/idempotent.sh"

SERVER="${1:?usage: deploy.sh <nginx|apache> [ssh-host]}"
SSH_HOST="${2:-}"
GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
COMPOSE_PROFILE_ARGS=()
[ "$SERVER" = "apache" ] && COMPOSE_PROFILE_ARGS=(--profile apache)

log() { echo "[deploy] $*"; }

case "$SERVER" in
    nginx|apache) ;;
    *) log "unknown server '$SERVER', expected nginx or apache"; exit 1 ;;
esac

# run <command...> - locally, or over SSH when SSH_HOST is set. Centralizing
# this is what lets every check below work the same way whether the target
# is this machine or a remote EC2 host.
run() {
    if [ -n "$SSH_HOST" ]; then
        ssh -o StrictHostKeyChecking=accept-new "$SSH_HOST" "$@"
    else
        bash -c "$*"
    fi
}

# --- 1. Docker present on the target? Install only if missing. ---
ensure_docker() {
    if run "command -v docker >/dev/null 2>&1"; then
        log "docker already installed on target, skipping install"
    else
        log "docker not found on target, installing"
        run "curl -fsSL https://get.docker.com | sh && sudo systemctl enable --now docker"
    fi

    if run "docker compose version >/dev/null 2>&1"; then
        log "docker compose plugin present"
    else
        log "!! docker compose plugin missing on target - the docker.com install script above should include it; aborting rather than guessing at a fix"
        exit 1
    fi
}

# --- 2. Required ports free (or already ours - a re-run of this same deploy
#        should not fail just because our own prior containers hold the port). ---
ensure_port_available() {
    local port="$1" compose_project="$2"
    if run "docker ps --filter label=com.docker.compose.project=$compose_project --format '{{.Names}}'" | grep -q .; then
        log "port ${port}: already held by this project's own containers, will be replaced in place"
        return 0
    fi
    if run "ss -ltn '( sport = :$port )' 2>/dev/null | grep -q ':$port' || netstat -ltn 2>/dev/null | grep -q ':$port '"; then
        log "!! port ${port} is in use by something other than this deploy - aborting rather than fighting it for the bind"
        exit 1
    fi
    log "port ${port}: free"
}

# --- 3. Sync the repo state the target will build from. For a real EC2
#        target this would be `git fetch && git checkout <sha>` against a
#        clone already on the host; kept as rsync here so this script has
#        no assumption about how the target got its previous checkout. ---
sync_source() {
    if [ -z "$SSH_HOST" ]; then
        log "local deploy, no sync needed"
        return 0
    fi
    log "syncing project source to ${SSH_HOST}:~/project-9-php-laravel-cd"
    rsync -az --delete \
        --exclude vendor --exclude .git --exclude '*.log' \
        "$PROJECT_DIR/" "${SSH_HOST}:~/project-9-php-laravel-cd/"
}

# --- 4. Validate config before it's live, not after ---
validate_configs() {
    log "php -l on every tracked PHP file"
    local f
    while IFS= read -r -d '' f; do
        php_syntax_valid "$f" || { log "!! syntax error in $f"; exit 1; }
    done < <(git -C "$PROJECT_DIR/app" ls-files -z '*.php')

    log "docker build (config-only stages compile cleanly, catches Dockerfile/config typos before touching the running stack)"
    (cd "$PROJECT_DIR" && docker build -q -f docker/nginx/Dockerfile -t "nginx:predeploy-check" . >/dev/null)
    (cd "$PROJECT_DIR" && docker build -q -f docker/apache/Dockerfile -t "apache:predeploy-check" . >/dev/null)
}

# --- 5. Bring the stack up, then prove it's actually serving before
#        declaring success - a deploy that "ran" but never went healthy is
#        a failed deploy, not a slow success. ---
roll_out() {
    local compose_project="project9-${SERVER}"
    local port
    [ "$SERVER" = "nginx" ] && port=8080 || port=8081

    ensure_port_available "$port" "$compose_project"

    local compose_cmd="cd ~/project-9-php-laravel-cd 2>/dev/null || cd $PROJECT_DIR; docker compose -p $compose_project ${COMPOSE_PROFILE_ARGS[*]} up --build -d php $SERVER"
    log "rolling out ${SERVER} (compose project: ${compose_project})"
    run "$compose_cmd"

    log "waiting for ${SERVER} to report healthy"
    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if run "curl -sf http://127.0.0.1:${port}/healthz >/dev/null"; then
            log "${SERVER} is healthy on :${port}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    log "!! ${SERVER} never became healthy after rollout - leaving containers running for inspection (docker compose -p ${compose_project} logs), not auto-rolling-back (portfolio scope: see project-9's ecom1 sibling for a rollback-capable version)"
    exit 1
}

log "deploying ${SERVER} (${GIT_SHA})${SSH_HOST:+ to $SSH_HOST}"
ensure_docker
sync_source
validate_configs
roll_out
log "done"
