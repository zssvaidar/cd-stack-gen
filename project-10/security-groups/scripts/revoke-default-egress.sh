#!/usr/bin/env bash
# Revokes the "allow all outbound" rule AWS creates automatically on every new security group.
# Run this before adding narrower egress rules for a tier that doesn't need unrestricted
# outbound access (a database tier, typically - it should only ever talk back to whoever
# opened the connection, plus maybe HTTPS out for patching).
#
# Usage: ./revoke-default-egress.sh <sg-id>
set -euo pipefail

SG_ID="${1:?usage: revoke-default-egress.sh <sg-id>}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

aws ec2 revoke-security-group-egress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --ip-permissions IpProtocol=-1,IpRanges='[{CidrIp=0.0.0.0/0}]'

echo "revoked default allow-all egress from $SG_ID"
