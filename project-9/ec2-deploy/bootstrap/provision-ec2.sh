#!/usr/bin/env bash
# Launches the EC2 host that ec2-deploy/Jenkinsfile deploys containers to.
# Docker is installed automatically via cloud-init-docker.sh (user-data).
#
# Required env vars:
#   AMI_ID              e.g. an Amazon Linux 2023 AMI for your region
#   KEY_NAME             an existing EC2 key pair - use the date_name printed by
#                        ../../agent-keys/generate-and-store.sh create, which already imported it
#   SECURITY_GROUP_ID    must allow inbound SSH (22) and whatever app port you deploy
#   SUBNET_ID
# Optional:
#   INSTANCE_TYPE (default t3.micro), AWS_REGION (default ap-northeast-1)
set -euo pipefail

: "${AMI_ID:?set AMI_ID}"
: "${KEY_NAME:?set KEY_NAME}"
: "${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID}"
: "${SUBNET_ID:?set SUBNET_ID}"

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "file://$SCRIPT_DIR/cloud-init-docker.sh" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cd-stack-app-host},{Key=project,Value=project-9}]' \
    --query 'Instances[0].InstanceId' --output text)

echo "launched $INSTANCE_ID, waiting for it to be running..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

echo "public IP:"
aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
