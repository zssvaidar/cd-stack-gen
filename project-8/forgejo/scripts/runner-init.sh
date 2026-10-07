#!/bin/sh
# Runner side of the shared-secret registration (forgejo-setup.sh does the Forgejo side), then a
# config.yml rebuilt from the environment on every start - change RUNNER_LABELS/RUNNER_CAPACITY
# in .env and `docker compose up -d` applies it - then the daemon itself.
set -eu
cd /data

if [ ! -f .runner ]; then
    # offline: just writes .runner; the daemon connects afterwards. If Forgejo hasn't finished
    # registering the secret yet, the daemon exits and the container restarts until it has.
    forgejo-runner create-runner-file --instance http://forgejo:3000 \
        --name "$RUNNER_NAME" --secret "$RUNNER_SECRET"
    echo "runner-init: created .runner"
fi

{
    echo "log:"
    echo "  level: info"
    echo "runner:"
    echo "  file: .runner"
    echo "  capacity: ${RUNNER_CAPACITY}"
    echo "  timeout: 3h"
    echo "  labels:"
    # RUNNER_LABELS is comma separated "<runs-on name>:docker://<image>"
    echo "$RUNNER_LABELS" | tr ',' '\n' | sed '/^$/d; s/^/    - "/; s/$/"/'
    echo "cache:"
    echo "  enabled: true"
    echo "container:"
    # job containers join the compose network, so they can reach http://forgejo:3000 directly
    echo "  network: forgejo-net"
    echo "  privileged: false"
    # "-": jobs don't get the host's docker.sock mounted in - only the runner itself uses it
    echo '  docker_host: "-"'
} > config.yml

exec forgejo-runner daemon --config config.yml
