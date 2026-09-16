#!/usr/bin/env bash
# build.sh - composer install/validate against the mock app, then build the
# php/nginx/apache images. Safe to re-run: every step checks whether it's
# already done before doing it.
#
#   ./scripts/build.sh              # composer + all three images
#   ./scripts/build.sh --no-docker  # composer only (e.g. inside `test.sh`'s CI job)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/idempotent.sh
source "$SCRIPT_DIR/lib/idempotent.sh"

PHP_VERSION="${PHP_VERSION:-8.3}"
GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
NO_DOCKER=0
[ "${1:-}" = "--no-docker" ] && NO_DOCKER=1

log() { echo "[build] $*"; }

# --- 1. Host PHP 8 present? Only relevant when running composer/phpunit
#        directly on the build host instead of inside a container (e.g. a
#        Jenkins agent running this before docker build even starts). ---
ensure_host_php() {
    if command_exists php; then
        local ver
        ver="$(php -r 'echo PHP_MAJOR_VERSION;')"
        if [ "$ver" -ge 8 ]; then
            log "host PHP $(php -r 'echo PHP_VERSION;') already present, skipping install"
            return 0
        fi
        log "host PHP present but major version $ver < 8 - not attempting an in-place upgrade, aborting"
        exit 1
    fi

    if command_exists apt-get; then
        log "installing PHP ${PHP_VERSION} on the build host"
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends \
            "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml"
    else
        log "no host PHP and no apt-get to install one - falling back to composer/phpunit inside Docker instead"
        return 1
    fi
}

# --- 2. Composer install, only when composer.lock/vendor are out of sync ---
run_composer() {
    cd "$PROJECT_DIR/app"

    if ! command_exists composer; then
        log "composer not on host, skipping host-side composer install (docker build stage does its own)"
        return 0
    fi

    composer validate --strict

    if [ -d vendor ] && [ -f vendor/composer/installed.json ] \
        && [ vendor/composer/installed.json -nt composer.lock ]; then
        log "vendor/ already up to date with composer.lock, skipping composer install"
    else
        log "installing composer dependencies"
        composer install --no-interaction --prefer-dist
    fi
}

# --- 3. Docker images, skipped per-image when the source tree hasn't
#        changed since the last build with this tag. ---
build_image() {
    local name="$1" dockerfile="$2" tag="${name}:${GIT_SHA}"

    if docker_image_exists "$tag"; then
        log "${tag} already built for this commit, skipping (rm the image or bump GIT_SHA to force)"
        return 0
    fi

    log "building ${tag}"
    docker build \
        -f "$PROJECT_DIR/$dockerfile" \
        -t "$tag" \
        --build-arg "PHP_VERSION=${PHP_VERSION}" \
        "$PROJECT_DIR"
}

if command_exists php || command_exists apt-get; then
    ensure_host_php || true
fi
run_composer

if [ "$NO_DOCKER" -eq 1 ]; then
    log "done (--no-docker: skipped image builds)"
    exit 0
fi

if ! command_exists docker; then
    log "docker not available on this host - cannot build images, run scripts/test.sh instead for a PHP-only check"
    exit 1
fi

build_image php docker/php/Dockerfile
build_image nginx docker/nginx/Dockerfile
build_image apache docker/apache/Dockerfile

log "done: php:${GIT_SHA}, nginx:${GIT_SHA}, apache:${GIT_SHA}"
