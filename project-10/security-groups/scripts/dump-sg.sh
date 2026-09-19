#!/usr/bin/env bash
# Dumps a security group's full definition (all rules included) to a timestamped JSON file -
# a lightweight audit trail. Diff two dumps to see exactly what changed and when, instead of
# relying on CloudTrail archaeology after the fact.
#
# Usage: ./dump-sg.sh <sg-id> [output-dir]   (output-dir defaults to ./dumps, gitignored)
set -euo pipefail

SG_ID="${1:?usage: dump-sg.sh <sg-id> [output-dir]}"
OUT_DIR="${2:-dumps}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${SG_ID}_$(date +%Y%m%dT%H%M%S).json"

aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$SG_ID" \
    --output json > "$OUT_FILE"

echo "wrote $OUT_FILE"
