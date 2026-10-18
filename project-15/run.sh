#!/usr/bin/env bash
# Entry point for project-15 - same shape as project-11/12's run.sh: run.sh <verb> [args], each
# verb a manage_*.sh fragment, the shared wrapper/ creds in front.
#
#   run.sh secrets <env> <app> {push|list|pull|delete}
#
# secrets: wrapper/<env>/<app>/.env (= project-9/wrapper/<env>/<app>/.env, gitignored) <-> SSM
# Parameter Store, one SecureString per variable at $SSM_PREFIX/<env>/<app>/<KEY>. See README.md.

set -euo pipefail

cd "$(dirname "$0")"

source "wrapper/common/init.sh"
source "wrapper/config/.env"

# to stderr: `pull` writes the .env itself to stdout
{
    unset_aws
    set_root
    whoami
} >&2

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_REGION

usage() {
    echo
    echo "Usage: run.sh secrets <env> <app> {push|list|pull|delete}"
    echo
    echo "  push     store every variable in wrapper/<env>/<app>/.env as a SecureString (PRUNE=true also"
    echo "           deletes parameters no longer in the file)"
    echo "  list     parameter names under the path, no values"
    echo "  pull     print them back as a .env (KEY='value') on stdout - for local docker compose"
    echo "  delete   delete every parameter under the path (asks first; FORCE=true skips that)"
    exit 1
}

case "${1:-}" in
    secrets)
        ENV_NAME="${2:-}"
        APP_NAME="${3:-}"
        ACTION="${4:-}"
        [[ -n "$ENV_NAME" && -n "$APP_NAME" && "$ACTION" =~ ^(push|list|pull|delete)$ ]] || usage
        source ./manage_secrets.sh
        ;;
    *)
        usage
        ;;
esac
