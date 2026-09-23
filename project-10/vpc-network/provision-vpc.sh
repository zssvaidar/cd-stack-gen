#!/usr/bin/env bash
# Creates a VPC with DNS support/hostnames enabled and an attached Internet Gateway.
# Prints VPC_ID / IGW_ID as key=value lines on stdout (and nothing else) so provision-all.sh
# can `eval` the output directly - keep any future debug output here on stderr, not stdout.
#
# Usage: ./provision-vpc.sh <name> <cidr>   e.g. ./provision-vpc.sh myapp 10.0.0.0/16
set -euo pipefail

NAME="${1:?usage: provision-vpc.sh <name> <cidr>}"
CIDR="${2:?cidr required, e.g. 10.0.0.0/16}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

VPC_ID=$(aws ec2 create-vpc \
    --region "$AWS_REGION" \
    --cidr-block "$CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}-vpc},{Key=project,Value=project-10}]" \
    --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$AWS_REGION" \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}-igw},{Key=project,Value=project-10}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --region "$AWS_REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

echo "VPC_ID=$VPC_ID"
echo "IGW_ID=$IGW_ID"
