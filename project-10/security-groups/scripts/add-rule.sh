#!/usr/bin/env bash
# Adds one ingress or egress rule to a security group. Prefer --peer-sg over --cidr for
# anything talking to another resource in the same VPC: the rule reads as "traffic from the
# app tier" instead of a bare IP, and it never goes stale as instances are replaced - unlike
# a hardcoded CIDR, a security-group reference always tracks whatever currently carries that SG.
#
# Usage:
#   ./add-rule.sh --sg <sg-id> --direction ingress|egress --protocol tcp --port 22 \
#       (--cidr 203.0.113.4/32 | --peer-sg sg-xxxxxxxx) [--description "text"]
set -euo pipefail

SG_ID=""
DIRECTION=""
PROTOCOL=""
PORT=""
CIDR=""
PEER_SG=""
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sg) SG_ID="$2"; shift 2 ;;
        --direction) DIRECTION="$2"; shift 2 ;;
        --protocol) PROTOCOL="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --cidr) CIDR="$2"; shift 2 ;;
        --peer-sg) PEER_SG="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

: "${SG_ID:?--sg required}"
: "${PROTOCOL:?--protocol required}"
: "${PORT:?--port required}"

case "$DIRECTION" in
    ingress|egress) ;;
    *) echo "--direction must be ingress or egress" >&2; exit 1 ;;
esac

if [[ -z "$CIDR" && -z "$PEER_SG" ]]; then
    echo "one of --cidr or --peer-sg is required" >&2
    exit 1
fi
if [[ -n "$CIDR" && -n "$PEER_SG" ]]; then
    echo "pass only one of --cidr or --peer-sg" >&2
    exit 1
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

if [[ -n "$PEER_SG" ]]; then
    PEER="UserIdGroupPairs=[{GroupId=$PEER_SG,Description=\"$DESCRIPTION\"}]"
else
    PEER="IpRanges=[{CidrIp=$CIDR,Description=\"$DESCRIPTION\"}]"
fi

aws ec2 "authorize-security-group-${DIRECTION}" \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=$PROTOCOL,FromPort=$PORT,ToPort=$PORT,$PEER"

echo "added $DIRECTION rule to $SG_ID: $PROTOCOL/$PORT <-> ${PEER_SG:-$CIDR}"
