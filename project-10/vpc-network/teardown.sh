#!/usr/bin/env bash
# Tears down everything provision-all.sh created, in the order AWS requires: route table
# associations first, then subnets, then the Internet Gateway, then the VPC itself.
#
# If anything is still using this VPC (running instances, security groups other than the
# default one, ENIs) the subnet/VPC deletion steps will fail with AWS's own error - delete
# those first, then rerun. Rerunning after a partial failure will error on whatever earlier
# steps already succeeded; that's expected, not a bug to work around here.
#
# Usage: ./teardown.sh <name>
set -euo pipefail

NAME="${1:?usage: teardown.sh <name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/state/${NAME}.env"
[[ -f "$STATE_FILE" ]] || { echo "no state file at $STATE_FILE" >&2; exit 1; }
set -a; source "$STATE_FILE"; set +a

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

for RT_ID in "$PUBLIC_RT_ID" "$PRIVATE_RT_ID"; do
    ASSOC_IDS=$(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$RT_ID" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text)
    for ASSOC_ID in $ASSOC_IDS; do
        aws ec2 disassociate-route-table --region "$AWS_REGION" --association-id "$ASSOC_ID"
    done
    echo "deleting route table $RT_ID"
    aws ec2 delete-route-table --region "$AWS_REGION" --route-table-id "$RT_ID"
done

for SUBNET_ID in $PUBLIC_SUBNET_IDS $PRIVATE_SUBNET_IDS; do
    echo "deleting subnet $SUBNET_ID"
    aws ec2 delete-subnet --region "$AWS_REGION" --subnet-id "$SUBNET_ID"
done

echo "detaching + deleting igw $IGW_ID"
aws ec2 detach-internet-gateway --region "$AWS_REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
aws ec2 delete-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$IGW_ID"

echo "deleting vpc $VPC_ID"
aws ec2 delete-vpc --region "$AWS_REGION" --vpc-id "$VPC_ID"

rm -f "$STATE_FILE"
echo "done - $STATE_FILE removed"
