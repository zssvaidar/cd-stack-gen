#!/usr/bin/env bash
# Creates a public route table (default route -> Internet Gateway), associated with every
# public subnet, and a private route table (default route -> NAT Gateway), associated with
# every private subnet. This is what actually makes a subnet "public" or "private" - the
# map-public-ip-on-launch flag from provision-subnets.sh only controls whether a new instance
# gets a public IP; without the matching route, that IP wouldn't reach anywhere.
#
# Prints PUBLIC_RT_ID / PRIVATE_RT_ID as key=value lines on stdout and nothing else.
#
# Usage: ./provision-route-tables.sh <name> <vpc-id> <igw-id> <nat-gw-id> \
#            <public-subnet-id> [public-subnet-id ...] -- <private-subnet-id> [private-subnet-id ...]
set -euo pipefail

NAME="${1:?usage: see file header}"; shift
VPC_ID="${1:?vpc-id required}"; shift
IGW_ID="${1:?igw-id required}"; shift
NAT_GW_ID="${1:?nat-gw-id required}"; shift

PUBLIC_SUBNET_IDS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
    PUBLIC_SUBNET_IDS+=("$1")
    shift
done
shift || true   # drop the --
PRIVATE_SUBNET_IDS=("$@")

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

PUBLIC_RT_ID=$(aws ec2 create-route-table \
    --region "$AWS_REGION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-public-rt},{Key=project,Value=project-10}]" \
    --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PUBLIC_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
for subnet in "${PUBLIC_SUBNET_IDS[@]}"; do
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PUBLIC_RT_ID" --subnet-id "$subnet" >/dev/null
done

PRIVATE_RT_ID=$(aws ec2 create-route-table \
    --region "$AWS_REGION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-private-rt},{Key=project,Value=project-10}]" \
    --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PRIVATE_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" >/dev/null
for subnet in "${PRIVATE_SUBNET_IDS[@]}"; do
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PRIVATE_RT_ID" --subnet-id "$subnet" >/dev/null
done

echo "PUBLIC_RT_ID=$PUBLIC_RT_ID"
echo "PRIVATE_RT_ID=$PRIVATE_RT_ID"
