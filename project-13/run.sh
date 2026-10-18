#!/usr/bin/env bash
# Entry point for project-13 - Terraform this time instead of project-11/12's aws-cli scripts,
# but the same wrapper/ credentials setup in front of it:
#
#   run.sh bootstrap {init|plan|apply}                       the S3 state bucket (local state)
#   run.sh <env> <layer> {init|plan|apply|destroy|output}    e.g. run.sh dev network apply
#
# Every <env>/<layer> is its own root module under live/ with its own state key in the shared
# bucket, so `run.sh dev network destroy` can never touch prod, and a later app layer can't
# accidentally change the VPC it sits in. Anything after the action is passed straight
# through to terraform (e.g. run.sh prod network plan -out=prod.plan).

set -euo pipefail

cd "$(dirname "$0")"

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="${TF_STATE_BUCKET:-cd-stack-gen-tfstate-$ACCOUNT_ID}"

usage() {
    echo
    echo "Usage: run.sh bootstrap {init|plan|apply}"
    echo "Usage: run.sh <env> <layer> {init|plan|apply|destroy|output} [terraform args...]"
    echo
    echo "envs/layers:"
    for d in live/*/*/; do echo "  $(basename "$(dirname "$d")") $(basename "$d")"; done
    exit 1
}

case "${1:-}" in
    bootstrap)
        action="${2:-}"
        [[ "$action" =~ ^(init|plan|apply)$ ]] || usage
        if [[ "$action" == init ]]; then
            terraform -chdir=bootstrap init
        else
            terraform -chdir=bootstrap "$action" \
                -var "region=$AWS_REGION" \
                -var "bucket_name=$STATE_BUCKET" \
                "${@:3}"
        fi
        ;;
    "")
        usage
        ;;
    *)
        env="$1"
        layer="${2:-}"
        action="${3:-}"
        dir="live/$env/$layer"

        [[ -n "$layer" && -d "$dir" ]] || usage
        [[ "$action" =~ ^(init|plan|apply|destroy|output)$ ]] || usage

        tf_init() {
            terraform -chdir="$dir" init \
                -backend-config="bucket=$STATE_BUCKET" \
                -backend-config="region=$AWS_REGION" \
                "$@"
        }

        if [[ "$action" == init ]]; then
            tf_init "${@:4}"
        else
            [[ -d "$dir/.terraform" ]] || tf_init
            if [[ "$action" == output ]]; then
                terraform -chdir="$dir" output "${@:4}"
            else
                terraform -chdir="$dir" "$action" -var "region=$AWS_REGION" "${@:4}"
            fi
        fi
        ;;
esac
