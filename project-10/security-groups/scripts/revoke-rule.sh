#!/usr/bin/env bash
# Removes a rule by its rule ID (see list-rules.sh) instead of by re-specifying the same
# protocol/port/source tuple used to add it. The tuple-matching approach is a known footgun:
# it silently no-ops if the tuple doesn't match exactly, including whether the original rule
# had a description - reviewers routinely think a rule is gone when it isn't. Rule IDs don't
# have that problem.
#
# Usage: ./revoke-rule.sh --sg <sg-id> --direction ingress|egress --rule-id sgr-xxxxxxxx
set -euo pipefail

SG_ID=""
DIRECTION=""
RULE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sg) SG_ID="$2"; shift 2 ;;
        --direction) DIRECTION="$2"; shift 2 ;;
        --rule-id) RULE_ID="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

: "${SG_ID:?--sg required}"
: "${RULE_ID:?--rule-id required (see list-rules.sh)}"

case "$DIRECTION" in
    ingress|egress) ;;
    *) echo "--direction must be ingress or egress" >&2; exit 1 ;;
esac

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

aws ec2 "revoke-security-group-${DIRECTION}" \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --security-group-rule-ids "$RULE_ID"

echo "revoked $DIRECTION rule $RULE_ID from $SG_ID"
