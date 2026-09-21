#!/usr/bin/env bash
# Unified entry point: keys / network / ssm / instances, each a fragment sourced from here so
# they share Purpose, STATE_FILE, AWS_REGION and the credentials set_root configures - none
# of them set up their own AWS session.

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

Purpose="${PURPOSE:-testing}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STATE_FILE=state/$Purpose.env

# every manage_*.sh fragment appends to this file - create it (and state/) on first use
# instead of requiring it to already exist, so `run.sh network create` works cold.
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

case "$1" in
    keys)
        # note: no literal { } inside a :? message - bash's parameter-expansion parser
        # doesn't track those as plain text, and a stray } ends up appended to $NAME
        NAME="${2:?usage: run.sh keys <name> create/delete}"
        source ./manage_keys.sh
        ;;
    ssm)
        source ./manage_ssm.sh
        ;;
    network)
        source ./manage_network.sh
        ;;
    instances)
        NAME="${2:?usage: run.sh instances <name> <count> create/delete}"
        COUNT="${3:?usage: run.sh instances <name> <count> create/delete}"
        source ./manage_instances.sh
        ;;
    *)
        echo
        echo "Usage: run.sh keys <name> {create|delete}"
        echo "Usage: run.sh ssm {create|delete}"
        echo "Usage: run.sh network {create|delete}"
        echo "Usage: run.sh instances <name> <count> {create|delete}"
        exit 1
        ;;
esac
