#!/usr/bin/env bash
# Creates a tagged security group. Prints its GroupId on success.
# Untagged, undescribed security groups are how you end up with a dozen "sg-temp" groups
# nobody can identify six months later - always tag at creation time.
#
# Usage: ./create-sg.sh <name> <description> <vpc-id> [key=value ...]
# Extra key=value args become tags on top of Name and project.
set -euo pipefail

NAME="${1:?usage: create-sg.sh <name> <description> <vpc-id> [tag=value ...]}"
DESCRIPTION="${2:?description required}"
VPC_ID="${3:?vpc-id required}"
shift 3

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

TAG_SPEC="ResourceType=security-group,Tags=[{Key=Name,Value=$NAME},{Key=project,Value=project-10}"
for kv in "$@"; do
    TAG_SPEC="$TAG_SPEC,{Key=${kv%%=*},Value=${kv#*=}}"
done
TAG_SPEC="$TAG_SPEC]"

SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "$NAME" \
    --description "$DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$TAG_SPEC" \
    --query 'GroupId' --output text)

echo "$SG_ID"
