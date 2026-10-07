#!/bin/bash
# forgejo-setup one-shot: the setup the web installer would otherwise need a human for - an admin
# account and the runner's registration. Runs after the forgejo service is healthy, against the
# same /data volume (app.ini + SQLite DB). Both steps are idempotent, so it runs on every
# `docker compose up` and exits 0 when there's nothing to do.
set -euo pipefail

if ! [[ "$RUNNER_SECRET" =~ ^[0-9a-f]{40}$ ]]; then
    echo "forgejo-setup: RUNNER_SECRET must be exactly 40 lowercase hex chars (openssl rand -hex 20)" >&2
    exit 1
fi

APP_INI="${GITEA_CUSTOM:-/data/gitea}/conf/app.ini"
[[ -f "$APP_INI" ]] || { echo "forgejo-setup: $APP_INI not found - has the forgejo service started?" >&2; exit 1; }

# The forgejo CLI must run as the git user that owns /data (this container starts as root).
# Single-quoted commands so the variables are expanded by that inner shell from the environment,
# never spliced into the command string.
as_git() {
    if command -v su-exec >/dev/null 2>&1; then
        su-exec git bash -c "$1"
    else
        su git -s /bin/bash -c "$1"
    fi
}

if as_git 'forgejo admin user list --admin' | awk 'NR>1 {print $2}' | grep -qx "$FORGEJO_ADMIN_USER"; then
    echo "forgejo-setup: admin '$FORGEJO_ADMIN_USER' already exists"
else
    as_git 'forgejo admin user create --admin --username "$FORGEJO_ADMIN_USER" --password "$FORGEJO_ADMIN_PASSWORD" --email "$FORGEJO_ADMIN_EMAIL" --must-change-password=false'
    echo "forgejo-setup: created admin '$FORGEJO_ADMIN_USER'"
fi

# instance-wide runner, pre-registered with the shared secret; runner-init.sh uses the same
# secret on its side. Re-running with the same secret is a no-op.
as_git 'forgejo forgejo-cli actions register --name "$RUNNER_NAME" --secret "$RUNNER_SECRET"'
echo "forgejo-setup: runner '$RUNNER_NAME' registered"
