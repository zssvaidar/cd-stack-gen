#!/usr/bin/env bash
# Provisions a full VPC network end to end: VPC + Internet Gateway, 2 public + 2 private
# subnets across 2 AZs, a NAT Gateway for the private subnets, and the route tables that
# wire it all together. Writes every resource ID to state/<name>.env so other scripts
# (../security-groups, ../../project-9/ec2-deploy) can source it instead of copy-pasting IDs.
#
# This sets up exactly one NAT Gateway (in the first public subnet) for cost/simplicity in a
# learning setup - a real HA design puts one NAT Gateway per AZ so a single AZ outage can't
# take outbound access from every private subnet with it. See README.md.
#
# Usage: ./provision-all.sh <name> [cidr]   (cidr defaults to 10.0.0.0/16)
set -euo pipefail

NAME="${1:?usage: provision-all.sh <name> [cidr]}"
CIDR="${2:-10.0.0.0/16}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/${NAME}.env"

if [[ -e "$STATE_FILE" ]]; then
    echo "$STATE_FILE already exists - pick a different name, or remove it first" >&2
    exit 1
fi
mkdir -p "$STATE_DIR"

echo "== vpc + internet gateway =="
eval "$("$SCRIPT_DIR/provision-vpc.sh" "$NAME" "$CIDR")"

echo "== subnets =="
eval "$("$SCRIPT_DIR/provision-subnets.sh" "$NAME" "$VPC_ID")"
read -ra PUBLIC_SUBNET_ARR <<< "$PUBLIC_SUBNET_IDS"
read -ra PRIVATE_SUBNET_ARR <<< "$PRIVATE_SUBNET_IDS"

echo "== nat gateway (in ${PUBLIC_SUBNET_ARR[0]}) =="
eval "$("$SCRIPT_DIR/provision-nat-gateway.sh" "$NAME" "${PUBLIC_SUBNET_ARR[0]}")"

echo "== route tables =="
eval "$("$SCRIPT_DIR/provision-route-tables.sh" "$NAME" "$VPC_ID" "$IGW_ID" "$NAT_GW_ID" \
    "${PUBLIC_SUBNET_ARR[@]}" -- "${PRIVATE_SUBNET_ARR[@]}")"

{
    echo "VPC_ID=$VPC_ID"
    echo "IGW_ID=$IGW_ID"
    echo "PUBLIC_SUBNET_IDS=\"$PUBLIC_SUBNET_IDS\""
    echo "PRIVATE_SUBNET_IDS=\"$PRIVATE_SUBNET_IDS\""
    echo "NAT_GW_ID=$NAT_GW_ID"
    echo "EIP_ALLOC_ID=$EIP_ALLOC_ID"
    echo "PUBLIC_RT_ID=$PUBLIC_RT_ID"
    echo "PRIVATE_RT_ID=$PRIVATE_RT_ID"
} > "$STATE_FILE"

echo
echo "done. state written to $STATE_FILE"
echo "  VPC_ID:            $VPC_ID"
echo "  public subnets:    $PUBLIC_SUBNET_IDS"
echo "  private subnets:   $PRIVATE_SUBNET_IDS"
echo
echo "source it with: set -a; source $STATE_FILE; set +a"
echo "then, e.g.:      ../security-groups/scripts/create-sg.sh myapp-app-sg app \"\$VPC_ID\""
