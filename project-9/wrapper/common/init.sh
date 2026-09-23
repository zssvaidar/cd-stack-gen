#!/usr/bin/env bash
# Shared by orchestrator scripts across project-9/project-10 - symlink this whole
# wrapper/ directory into a script's own folder (see its README) rather than copying it.

unset_aws() {
    # a leftover AWS_ACCESS_KEY_ID / AWS_SESSION_TOKEN exported earlier in the same shell
    # (e.g. from a previous vault-issued session) silently overrides whatever set_root just
    # configured, since env vars win over the aws cli's default profile - clear them first.
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN

    echo ran unset aws
}

set_root() {
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID_CREATOR"
    aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY_CREATOR"
    aws configure set region "${AWS_REGION:-ap-northeast-1}"

    echo ran set root
}

whoami() {
    aws sts get-caller-identity
}
