#!/usr/bin/env bash
# test.sh - lint + PHPUnit against the mock app, then (unless --unit-only) a
# container smoke test: bring the compose stack up, hit both nginx and
# apache through to php-fpm, tear it down. This is what Jenkins/CI should
# call between build.sh and deploy.sh.
#
#   ./scripts/test.sh              # unit tests + container smoke test
#   ./scripts/test.sh --unit-only  # just phpunit/lint, no docker required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/idempotent.sh
source "$SCRIPT_DIR/lib/idempotent.sh"

UNIT_ONLY=0
[ "${1:-}" = "--unit-only" ] && UNIT_ONLY=1

log() { echo "[test] $*"; }

run_unit_tests() {
    cd "$PROJECT_DIR/app"

    if ! command_exists composer || [ ! -d vendor ]; then
        log "vendor/ missing or composer unavailable - run scripts/build.sh first"
        exit 1
    fi

    log "php -l across src/ and tests/"
    composer run lint

    log "phpunit"
    composer run test
}

run_container_smoke_test() {
    if ! command_exists docker; then
        log "docker not available, skipping container smoke test (use --unit-only on hosts without docker)"
        return 0
    fi

    cd "$PROJECT_DIR"
    local compose_project="project9-smoke-$$"
    local cleanup_ran=0
    cleanup() {
        [ "$cleanup_ran" -eq 1 ] && return
        cleanup_ran=1
        log "tearing down smoke-test stack"
        docker compose -p "$compose_project" --profile apache down -v --remove-orphans >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    log "bringing up php + nginx + apache for the smoke test (project: ${compose_project})"
    docker compose -p "$compose_project" --profile apache up --build -d

    local ok=1
    for target in "8080:nginx" "8081:apache"; do
        local port="${target%%:*}" name="${target##*:}"
        log "waiting for ${name} on :${port}/healthz"
        local attempt=0 up=0
        while [ "$attempt" -lt 20 ]; do
            if curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null; then
                up=1
                break
            fi
            attempt=$((attempt + 1))
            sleep 2
        done
        if [ "$up" -ne 1 ]; then
            log "!! ${name} never became healthy"
            docker compose -p "$compose_project" logs "$name" || true
            ok=0
            continue
        fi

        log "checking ${name} -> php-fpm round trip on /"
        local body status
        body="$(curl -s "http://127.0.0.1:${port}/")"
        status="$(echo "$body" | php -r 'echo json_decode(stream_get_contents(STDIN))->ok ? "1" : "0";' 2>/dev/null || echo 0)"
        if [ "$status" != "1" ]; then
            log "!! ${name} responded but the app reported not-ok: $body"
            ok=0
        else
            log "${name}: OK"
        fi
    done

    [ "$ok" -eq 1 ]
}

run_unit_tests
if [ "$UNIT_ONLY" -eq 0 ]; then
    run_container_smoke_test
fi

log "all tests passed"
