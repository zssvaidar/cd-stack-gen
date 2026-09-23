#!/usr/bin/env bash
# Read-only audit for the two security-group mistakes that actually matter in practice:
#   1. a sensitive port (or literally everything) open to the internet
#   2. a security group that isn't attached to anything, so nobody ever reviews its rules
# Makes no changes. Exits nonzero if anything was flagged, so it can be wired into CI as a
# gate rather than something a human has to remember to run.
#
# Optional env vars: AWS_REGION, SENSITIVE_PORTS (default: common admin/db/cache/search ports)
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SENSITIVE_PORTS="${SENSITIVE_PORTS:-22 3389 3306 5432 6379 27017 9200 5601 9092}"
FOUND=0

echo "== open to the internet on sensitive ports =="
for PORT in $SENSITIVE_PORTS; do
    for CIDR in 0.0.0.0/0 ::/0; do
        MATCHES=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=ip-permission.cidr,Values=$CIDR" "Name=ip-permission.from-port,Values=$PORT" \
            --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || true)
        if [[ -n "$MATCHES" ]]; then
            echo "port $PORT open to $CIDR:"
            echo "$MATCHES" | sed 's/^/  /'
            FOUND=1
        fi
    done
done

# a rule scoped to "all protocols" (-1) usually has FromPort/ToPort of -1 too, so the
# port-filtered loop above won't catch it - check separately, since this is the worst case.
echo
echo "== open to the internet on ALL ports/protocols =="
for CIDR in 0.0.0.0/0 ::/0; do
    MATCHES=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=ip-permission.cidr,Values=$CIDR" "Name=ip-permission.protocol,Values=-1" \
        --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || true)
    if [[ -n "$MATCHES" ]]; then
        echo "all traffic open to $CIDR:"
        echo "$MATCHES" | sed 's/^/  /'
        FOUND=1
    fi
done

echo
echo "== not attached to any network interface =="
ALL_SG_IDS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --query 'SecurityGroups[].GroupId' --output text)
for SG_ID in $ALL_SG_IDS; do
    ATTACHED=$(aws ec2 describe-network-interfaces \
        --region "$AWS_REGION" \
        --filters "Name=group-id,Values=$SG_ID" \
        --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text)
    if [[ -z "$ATTACHED" || "$ATTACHED" == "None" ]]; then
        echo "  $SG_ID (unused)"
        FOUND=1
    fi
done

if [[ "$FOUND" -eq 1 ]]; then
    echo
    echo "issues found - see above" >&2
    exit 1
fi

echo
echo "no issues found"
