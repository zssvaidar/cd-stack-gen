#!/bin/bash
# Replaces the Forgejo image's CMD: starts Forgejo exactly as the image would (s6-svscan), waits
# until it answers, then does the one-time setup the web installer would otherwise need a human
# for - an admin account and the runner's registration. Both steps are idempotent, so this runs
# unchanged on every restart.
set -euo pipefail

if ! [[ "$RUNNER_SECRET" =~ ^[0-9a-f]{40}$ ]]; then
    echo "forgejo-init: RUNNER_SECRET must be exactly 40 lowercase hex chars (openssl rand -hex 20)" >&2
    exit 1
fi

/bin/s6-svscan /etc/s6 &
S6_PID=$!
trap 'kill -TERM "$S6_PID" 2>/dev/null; wait "$S6_PID"' TERM INT

until wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1; do
    kill -0 "$S6_PID" 2>/dev/null || { echo "forgejo-init: forgejo exited during startup" >&2; exit 1; }
    sleep 2
done

# the forgejo CLI must run as the git user that owns /data; single quotes so the variables are
# expanded by that inner shell (su keeps the environment), not spliced into the command string
as_git() { su git -s /bin/bash -c "$1"; }

if as_git 'forgejo admin user list --admin' | awk 'NR>1 {print $2}' | grep -qx "$FORGEJO_ADMIN_USER"; then
    echo "forgejo-init: admin '$FORGEJO_ADMIN_USER' already exists"
else
    as_git 'forgejo admin user create --admin --username "$FORGEJO_ADMIN_USER" --password "$FORGEJO_ADMIN_PASSWORD" --email "$FORGEJO_ADMIN_EMAIL" --must-change-password=false'
    echo "forgejo-init: created admin '$FORGEJO_ADMIN_USER'"
fi

# instance-wide runner, pre-registered with the shared secret; runner-init.sh uses the same
# secret on its side. Re-running with the same secret is a no-op.
as_git 'forgejo forgejo-cli actions register --name "$RUNNER_NAME" --secret "$RUNNER_SECRET"'
echo "forgejo-init: runner '$RUNNER_NAME' registered"

wait "$S6_PID"
