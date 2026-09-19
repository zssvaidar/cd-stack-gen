#!/usr/bin/env bash
# Attaches one or more security groups to a running instance WITHOUT dropping the ones
# already attached. `aws ec2 modify-instance-attribute --groups` REPLACES the instance's
# entire security-group list - passing just the new group ID would silently strip every
# other group already on it. This reads the current list first and merges.
#
# Only touches the instance's primary network interface. For a multi-ENI instance, target
# the right interface directly with:
#   aws ec2 modify-network-interface-attribute --network-interface-id eni-xxxx --groups ...
#
# Usage: ./attach-sg.sh <instance-id> <sg-id> [sg-id ...]
set -euo pipefail

INSTANCE_ID="${1:?usage: attach-sg.sh <instance-id> <sg-id> [sg-id ...]}"
shift
NEW_SG_IDS=("$@")
[[ ${#NEW_SG_IDS[@]} -gt 0 ]] || { echo "at least one sg-id required" >&2; exit 1; }

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

CURRENT=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)

MERGED=$(printf '%s\n' $CURRENT "${NEW_SG_IDS[@]}" | sort -u | tr '\n' ' ')

echo "setting $INSTANCE_ID security groups to: $MERGED"
aws ec2 modify-instance-attribute \
    --region "$AWS_REGION" \
    --instance-id "$INSTANCE_ID" \
    --groups $MERGED
