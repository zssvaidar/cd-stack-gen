#!/usr/bin/env bash
# Lists every ingress + egress rule on a security group, rule IDs included - the first thing
# to run before revoke-rule.sh, and generally the fastest way to sanity-check what a group
# actually allows instead of trusting memory.
#
# Usage: ./list-rules.sh <sg-id>
set -euo pipefail

SG_ID="${1:?usage: list-rules.sh <sg-id>}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

aws ec2 describe-security-group-rules \
    --region "$AWS_REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query 'SecurityGroupRules[].{Id:SecurityGroupRuleId,Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:CidrIpv4,PeerSg:ReferencedGroupInfo.GroupId,Desc:Description}' \
    --output table
