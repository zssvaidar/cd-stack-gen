#!/bin/sh
# Runs as PID 1 inside the php container (ENTRYPOINT in ../Dockerfile), before
# execing php-fpm. Its only job: get secrets from Vault into this process's
# environment, then get out of the way. See ../../docs/vault-secret-injection.md
# for the reasoning behind this approach vs. the alternatives (Vault Agent
# sidecar, ECS `secrets` block, ambient env vars).
#
# Deliberately POSIX sh, not bash - the php:*-alpine base doesn't ship bash,
# and this script has no need for bash-only features.
set -eu

log() { echo "[entrypoint] $*" >&2; }

# --- 1. Pick opcache validate_timestamps for this environment (see php.ini's
#        header comment: this file only sets the shared defaults) ---
APP_ENV="${APP_ENV:-local}"
APP_CONF_D=/usr/local/etc/php/app-conf.d
if [ "$APP_ENV" = "production" ]; then
    mv "$APP_CONF_D/opcache-prod.ini.disabled" "$APP_CONF_D/opcache-prod.ini" 2>/dev/null || true
    rm -f "$APP_CONF_D/opcache-dev.ini.disabled"
else
    mv "$APP_CONF_D/opcache-dev.ini.disabled" "$APP_CONF_D/opcache-dev.ini" 2>/dev/null || true
    rm -f "$APP_CONF_D/opcache-prod.ini.disabled"
fi

# --- 2. Pull secrets from Vault, if configured. Local dev without Vault
#        (VAULT_ADDR unset) is a supported path, not an error - `docker
#        compose up` should work with no Vault running at all. ---
if [ -n "${VAULT_ADDR:-}" ]; then
    for bin in vault jq; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "VAULT_ADDR is set but '$bin' is not installed in this image - aborting"
            exit 1
        fi
    done

    if [ -n "${VAULT_TOKEN:-}" ]; then
        log "using supplied VAULT_TOKEN"
    elif [ -n "${VAULT_ROLE_ID:-}" ] && [ -n "${VAULT_SECRET_ID:-}" ]; then
        log "logging into Vault via AppRole (role_id only, secret_id withheld from logs)"
        VAULT_TOKEN="$(vault write -field=token auth/approle/login \
            role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")"
        export VAULT_TOKEN
        unset VAULT_ROLE_ID VAULT_SECRET_ID
    else
        log "VAULT_ADDR is set but neither VAULT_TOKEN nor VAULT_ROLE_ID+VAULT_SECRET_ID were provided - aborting"
        exit 1
    fi

    VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/medusa-twenty/${APP_ENV}/php-app}"
    log "fetching secrets from ${VAULT_SECRET_PATH} (values not logged)"

    secrets_json="$(vault kv get -format=json "$VAULT_SECRET_PATH")" || {
        log "failed to read $VAULT_SECRET_PATH from Vault"
        exit 1
    }

    # Export every key in the secret's data map as an env var, uppercased-as-is
    # (Vault key names are expected to already be valid env var names, e.g.
    # DB_PASSWORD, APP_KEY - this does not rename or transform them).
    key_count=0
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        export "$key=$value"
        key_count=$((key_count + 1))
    done <<EOF
$(echo "$secrets_json" | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"')
EOF

    # Never let the token or role credentials leak into the app's env or a
    # `docker inspect`/`printenv` from inside the container.
    unset VAULT_TOKEN
    log "injected ${key_count} secret(s) from Vault into the process environment"
elif [ -f /var/www/html/.env ]; then
    log "VAULT_ADDR not set, loading /var/www/html/.env for local dev (never do this in staging/prod)"
    set -a
    # shellcheck disable=SC1091
    . /var/www/html/.env
    set +a
else
    log "VAULT_ADDR not set and no .env present - continuing with only the ambient container environment"
fi

# --- 3. Hand off to the real command (php-fpm by default, see Dockerfile CMD) ---
exec "$@"
