#!/usr/bin/env bash
# One-time bootstrap: log group + ECS cluster + Fargate service.
# Run the Jenkinsfile's "Register task definition" stage at least once before this,
# since create-service needs an existing task definition family to start from.
#
# Required env vars:
#   AWS_REGION, ECS_CLUSTER, ECS_SERVICE, TASK_FAMILY,
#   SUBNET_IDS (comma separated), SECURITY_GROUP_ID
# Optional:
#   DESIRED_COUNT (default 1)
set -euo pipefail

: "${AWS_REGION:?}"
: "${ECS_CLUSTER:?}"
: "${ECS_SERVICE:?}"
: "${TASK_FAMILY:?}"
: "${SUBNET_IDS:?}"
: "${SECURITY_GROUP_ID:?}"

DESIRED_COUNT="${DESIRED_COUNT:-1}"

aws logs create-log-group \
    --region "$AWS_REGION" \
    --log-group-name "/ecs/${TASK_FAMILY}" 2>/dev/null || true

aws ecs create-cluster --region "$AWS_REGION" --cluster-name "$ECS_CLUSTER"

aws ecs create-service \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --service-name "$ECS_SERVICE" \
    --task-definition "$TASK_FAMILY" \
    --desired-count "$DESIRED_COUNT" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SECURITY_GROUP_ID}],assignPublicIp=ENABLED}"
