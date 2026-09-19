#!/usr/bin/env bash
# Allocates an Elastic IP and creates a NAT Gateway in a public subnet, so instances in
# private subnets can reach the internet outbound (patching, pulling images) without being
# reachable from it. NAT Gateways bill hourly plus per-GB even sitting idle - see
# ../teardown.sh when you're done, don't leave one running in a learning account.
#
# Prints EIP_ALLOC_ID / NAT_GW_ID as key=value lines on stdout and nothing else, so
# provision-all.sh can `eval` the output directly - status messages go to stderr.
#
# Usage: ./provision-nat-gateway.sh <name> <public-subnet-id>
set -euo pipefail

NAME="${1:?usage: provision-nat-gateway.sh <name> <public-subnet-id>}"
PUBLIC_SUBNET_ID="${2:?public-subnet-id required}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

EIP_ALLOC_ID=$(aws ec2 allocate-address \
    --region "$AWS_REGION" \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat-eip},{Key=project,Value=project-10}]" \
    --query 'AllocationId' --output text)

NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --region "$AWS_REGION" \
    --subnet-id "$PUBLIC_SUBNET_ID" \
    --allocation-id "$EIP_ALLOC_ID" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat},{Key=project,Value=project-10}]" \
    --query 'NatGateway.NatGatewayId' --output text)

echo "waiting for nat gateway to become available..." >&2
aws ec2 wait nat-gateway-available --region "$AWS_REGION" --nat-gateway-ids "$NAT_GW_ID"

echo "EIP_ALLOC_ID=$EIP_ALLOC_ID"
echo "NAT_GW_ID=$NAT_GW_ID"
