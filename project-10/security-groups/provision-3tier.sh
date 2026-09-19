#!/usr/bin/env bash
# Provisions three security groups wired together the way a bastion -> app -> db stack
# should be: each tier only accepts traffic from the specific security group in front of it,
# never from a CIDR block, so the rules stay correct as instances are replaced and never need
# an IP list maintained by hand.
#
#   bastion-sg  <- MAINTENANCE_CIDR on 22                          (only door open to a human)
#   app-sg      <- bastion-sg on 22, <- 0.0.0.0/0 on APP_PORT      (public web tier)
#   db-sg       <- app-sg on DB_PORT only                          (nothing else can reach it,
#                                                                    not even the bastion)
#
# db-sg also has its default allow-all egress revoked and replaced with just HTTPS out - a
# database has no legitimate reason to initiate arbitrary outbound connections.
#
# Usage: VPC_ID=vpc-xxxx MAINTENANCE_CIDR=203.0.113.4/32 ./provision-3tier.sh <name-prefix>
# Optional env vars: APP_PORT (default 3000), DB_PORT (default 5432), AWS_REGION
set -euo pipefail

: "${VPC_ID:?set VPC_ID}"
: "${MAINTENANCE_CIDR:?set MAINTENANCE_CIDR, e.g. your office/VPN IP as a /32}"
PREFIX="${1:?usage: provision-3tier.sh <name-prefix>}"

APP_PORT="${APP_PORT:-3000}"
DB_PORT="${DB_PORT:-5432}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASTION_SG=$("$SCRIPT_DIR/scripts/create-sg.sh" "${PREFIX}-bastion-sg" "bastion host - ssh jump box" "$VPC_ID" tier=bastion)
APP_SG=$("$SCRIPT_DIR/scripts/create-sg.sh" "${PREFIX}-app-sg" "application tier" "$VPC_ID" tier=app)
DB_SG=$("$SCRIPT_DIR/scripts/create-sg.sh" "${PREFIX}-db-sg" "database tier" "$VPC_ID" tier=db)

echo "bastion-sg=$BASTION_SG app-sg=$APP_SG db-sg=$DB_SG"

# bastion: ssh only from the maintenance CIDR, nothing else inbound
"$SCRIPT_DIR/scripts/add-rule.sh" --sg "$BASTION_SG" --direction ingress --protocol tcp --port 22 \
    --cidr "$MAINTENANCE_CIDR" --description "maintenance access"

# app: ssh only via the bastion (never straight from the internet); app port is public
# (swap --cidr 0.0.0.0/0 for --peer-sg <alb-sg> once there's a load balancer in front of it)
"$SCRIPT_DIR/scripts/add-rule.sh" --sg "$APP_SG" --direction ingress --protocol tcp --port 22 \
    --peer-sg "$BASTION_SG" --description "ssh via bastion"
"$SCRIPT_DIR/scripts/add-rule.sh" --sg "$APP_SG" --direction ingress --protocol tcp --port "$APP_PORT" \
    --cidr "0.0.0.0/0" --description "public app traffic"

# db: only the app tier can reach it, on the db port, nothing else - not even the bastion
"$SCRIPT_DIR/scripts/add-rule.sh" --sg "$DB_SG" --direction ingress --protocol tcp --port "$DB_PORT" \
    --peer-sg "$APP_SG" --description "app tier -> db"

# a db tier has no business reaching arbitrary outbound destinations - drop the default
# allow-all egress and only allow what patching needs
"$SCRIPT_DIR/scripts/revoke-default-egress.sh" "$DB_SG"
"$SCRIPT_DIR/scripts/add-rule.sh" --sg "$DB_SG" --direction egress --protocol tcp --port 443 \
    --cidr "0.0.0.0/0" --description "os/package patching over https"

echo
echo "done."
echo "  bastion: $BASTION_SG  (attach to your bastion instance)"
echo "  app:     $APP_SG      (attach to app instances, e.g. via ../ec2-deploy)"
echo "  db:      $DB_SG       (attach to the database instance)"
echo
echo "attach any of these to a running instance with:"
echo "  scripts/attach-sg.sh <instance-id> <sg-id> [sg-id ...]"
