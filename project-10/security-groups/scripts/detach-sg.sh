#!/usr/bin/env bash
# Removes specific security group(s) from a running instance, keeping the rest attached.
# Same "--groups replaces the whole list" caveat as attach-sg.sh applies here too - this reads
# the current list, drops the ones you asked to remove, and sets what's left. Refuses to leave
# the instance with zero security groups, since AWS doesn't allow that anyway.
#
# Usage: ./detach-sg.sh <instance-id> <sg-id> [sg-id ...]
set -euo pipefail

INSTANCE_ID="${1:?usage: detach-sg.sh <instance-id> <sg-id> [sg-id ...]}"
shift
REMOVE_SG_IDS=("$@")
[[ ${#REMOVE_SG_IDS[@]} -gt 0 ]] || { echo "at least one sg-id required" >&2; exit 1; }

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

CURRENT=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)

REMAINING=""
for sg in $CURRENT; do
    keep=true
    for remove in "${REMOVE_SG_IDS[@]}"; do
        [[ "$sg" == "$remove" ]] && keep=false
    done
    [[ "$keep" == true ]] && REMAINING="$REMAINING $sg"
done
REMAINING="$(echo "$REMAINING" | xargs)"

if [[ -z "$REMAINING" ]]; then
    echo "refusing to detach: instance would be left with zero security groups" >&2
    exit 1
fi

echo "setting $INSTANCE_ID security groups to: $REMAINING"
aws ec2 modify-instance-attribute \
    --region "$AWS_REGION" \
    --instance-id "$INSTANCE_ID" \
    --groups $REMAINING
