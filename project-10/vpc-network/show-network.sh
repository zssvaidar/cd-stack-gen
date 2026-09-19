#!/usr/bin/env bash
# Prints a human-readable summary of a network provisioned by provision-all.sh: the VPC,
# its subnets (with public/private tier and AZ), route tables, and NAT gateway state.
# Read-only.
#
# Usage: ./show-network.sh <name>
set -euo pipefail

NAME="${1:?usage: show-network.sh <name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/state/${NAME}.env"
[[ -f "$STATE_FILE" ]] || { echo "no state file at $STATE_FILE - did you run provision-all.sh $NAME?" >&2; exit 1; }
set -a; source "$STATE_FILE"; set +a

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

echo "== vpc $VPC_ID =="
aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].{CidrBlock:CidrBlock,State:State}' --output table

echo "== subnets =="
aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].{Id:SubnetId,Az:AvailabilityZone,Cidr:CidrBlock,PublicIp:MapPublicIpOnLaunch,Tier:Tags[?Key==`tier`]|[0].Value}' \
    --output table

echo "== route tables =="
aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[].{Id:RouteTableId,Routes:Routes[].DestinationCidrBlock,Associations:Associations[].SubnetId}' \
    --output table

echo "== nat gateway $NAT_GW_ID =="
aws ec2 describe-nat-gateways --region "$AWS_REGION" --nat-gateway-ids "$NAT_GW_ID" \
    --query 'NatGateways[0].{State:State,SubnetId:SubnetId}' --output table
