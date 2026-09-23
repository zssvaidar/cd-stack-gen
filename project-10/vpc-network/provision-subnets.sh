#!/usr/bin/env bash
# Creates public + private subnets across two AZs - spreading across AZs is the actual point
# of "highly available"; a single-AZ setup isn't. Public subnets get map-public-ip-on-launch;
# private ones don't. That flag only controls whether a new instance *gets* a public IP -
# provision-route-tables.sh is what actually makes a subnet's traffic reach the internet or
# not, so both pieces matter, not just this one.
#
# Prints PUBLIC_SUBNET_IDS / PRIVATE_SUBNET_IDS (space-separated) as key=value lines on
# stdout and nothing else, so provision-all.sh can `eval` the output directly.
#
# Usage: ./provision-subnets.sh <name> <vpc-id>
# Optional env vars: AWS_REGION, AZS ("<region>a <region>c" by default),
#                    PUBLIC_CIDRS ("10.0.0.0/24 10.0.1.0/24" by default),
#                    PRIVATE_CIDRS ("10.0.10.0/24 10.0.11.0/24" by default)
set -euo pipefail

NAME="${1:?usage: provision-subnets.sh <name> <vpc-id>}"
VPC_ID="${2:?vpc-id required}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AZS="${AZS:-${AWS_REGION}a ${AWS_REGION}c}"
PUBLIC_CIDRS="${PUBLIC_CIDRS:-10.0.0.0/24 10.0.1.0/24}"
PRIVATE_CIDRS="${PRIVATE_CIDRS:-10.0.10.0/24 10.0.11.0/24}"

read -ra AZ_ARR <<< "$AZS"
read -ra PUB_ARR <<< "$PUBLIC_CIDRS"
read -ra PRIV_ARR <<< "$PRIVATE_CIDRS"

PUBLIC_SUBNET_IDS=()
for i in "${!PUB_ARR[@]}"; do
    AZ="${AZ_ARR[$((i % ${#AZ_ARR[@]}))]}"
    SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --availability-zone "$AZ" \
        --cidr-block "${PUB_ARR[$i]}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-public-${i}},{Key=project,Value=project-10},{Key=tier,Value=public}]" \
        --query 'Subnet.SubnetId' --output text)
    aws ec2 modify-subnet-attribute --region "$AWS_REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch '{"Value":true}'
    PUBLIC_SUBNET_IDS+=("$SUBNET_ID")
done

PRIVATE_SUBNET_IDS=()
for i in "${!PRIV_ARR[@]}"; do
    AZ="${AZ_ARR[$((i % ${#AZ_ARR[@]}))]}"
    SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --availability-zone "$AZ" \
        --cidr-block "${PRIV_ARR[$i]}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-private-${i}},{Key=project,Value=project-10},{Key=tier,Value=private}]" \
        --query 'Subnet.SubnetId' --output text)
    PRIVATE_SUBNET_IDS+=("$SUBNET_ID")
done

echo "PUBLIC_SUBNET_IDS=\"${PUBLIC_SUBNET_IDS[*]}\""
echo "PRIVATE_SUBNET_IDS=\"${PRIVATE_SUBNET_IDS[*]}\""
