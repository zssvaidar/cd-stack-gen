#!/usr/bin/env bash
# Unified entry point for project-12 - same shape as project-11/run.sh: run.sh <verb> [args]
# {create|delete} sources the matching manage_*.sh fragment, all of them sharing one
# Purpose-tagged state log at state/$PURPOSE.env. Deploys bun-hydrate on ECS Fargate, reusing
# project-11's network (VPC, app-tier subnet/SG, egress gateway for outbound internet access)
# rather than provisioning a second one - `rds`/`worker`/`tunnel`/`alb` below all need that
# network to already exist (`../project-11/run.sh network create` first, and `run.sh egress
# gw create` there too, since Fargate tasks living in the private app subnet need it to reach
# ECR/CloudWatch/the Cloudflare edge).

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

Purpose="${PURPOSE:-testing}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STATE_FILE=state/$Purpose.env

mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

# project-11's own state - read-only from here. Sourced before $STATE_FILE so anything project-12
# appends under the same names (there shouldn't be any overlap) would still win.
NETWORK_STATE_FILE="../project-11/state/$Purpose.env"
if [[ -f "$NETWORK_STATE_FILE" ]]; then
    source "$NETWORK_STATE_FILE"
else
    echo "warning: $NETWORK_STATE_FILE not found - run '../project-11/run.sh network create' first" >&2
fi

case "$1" in
    rds)
        NAME="${2:?usage: run.sh rds <name> create/delete}"
        source ./manage_rds.sh
        ;;
    worker)
        NAME="${2:?usage: run.sh worker <name> create/delete}"
        source ./manage_ecs_worker.sh
        ;;
    tunnel)
        NAME="${2:?usage: run.sh tunnel <name> create/delete}"
        source ./manage_ecs_tunnel.sh
        ;;
    alb)
        NAME="${2:?usage: run.sh alb <name> create/delete}"
        source ./manage_ecs_alb.sh
        ;;
    *)
        echo
        echo "Usage: run.sh rds <name> {create|delete}"
        echo "Usage: run.sh worker <name> {create|delete}"
        echo "Usage: run.sh tunnel <name> {create|delete}"
        echo "Usage: run.sh alb <name> {create|delete}"
        exit 1
        ;;
esac
