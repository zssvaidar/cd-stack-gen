# Cloudflare Tunnel wiring shared by manage_egress_instance.sh and manage_egress_balancer.sh -
# sourced by them after $STATE_FILE, not by run.sh directly. Expects $Purpose, $AWS_REGION, $NAME
# and $TUNNEL_ROLE (egress-gateway / egress-balancer) to already be set.
#
# The token is passed once, on the command line, and goes straight into SSM Parameter Store as a
# SecureString - never into the AMI, user-data or SSM command history. The instance only ever
# receives the parameter's *name* and fetches the value itself (with its instance profile) each
# time cloudflared starts, so rotating it is: pass a new token on `sync`, done.
#
#   CLOUDFLARE_TUNNEL_TOKEN   the token (Zero Trust -> Networks -> Tunnels -> your tunnel ->
#                             install connector). Stored to CLOUDFLARE_TUNNEL_PARAM, or to
#                             /$Purpose/$TUNNEL_ROLE/$NAME/cloudflare-tunnel-token by default.
#   CLOUDFLARE_TUNNEL_PARAM   use an already-stored parameter instead (no token needed), or
#                             `none` to stop the tunnel on `sync`.
#
# The instance must be allowed to read that parameter: tunnel_prepare attaches an inline policy
# (ssm:GetParameter on exactly this parameter's ARN, nothing wider) to the role behind
# $INSTANCE_PROFILE_NAME, named cloudflare-tunnel-<purpose>-<role>-<name> so each gateway/balancer
# gets its own and `delete` removes just that one. The default aws/ssm KMS key needs no extra
# grant; a parameter encrypted with a customer-managed key also needs kms:Decrypt on that key.
#
# Which origin the tunnel forwards to (localhost:80 on the balancer, an app instance's private IP
# behind a plain gateway, ...) is set on the tunnel's public hostname in the Cloudflare dashboard -
# a token-run tunnel takes its ingress rules from there, not from anything on the instance.

CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
CLOUDFLARE_TUNNEL_PARAM="${CLOUDFLARE_TUNNEL_PARAM:-}"
TUNNEL_DEFAULT_PARAM="/$Purpose/$TUNNEL_ROLE/$NAME/cloudflare-tunnel-token"
TUNNEL_POLICY_NAME="cloudflare-tunnel-$Purpose-$TUNNEL_ROLE-$NAME"

# set = this run touches the tunnel at all; `sync` leaves it alone otherwise
TUNNEL_SET="${CLOUDFLARE_TUNNEL_TOKEN}${CLOUDFLARE_TUNNEL_PARAM}"

if [[ "$CLOUDFLARE_TUNNEL_PARAM" == "none" ]]; then
    [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]] || { echo "error: CLOUDFLARE_TUNNEL_TOKEN given together with CLOUDFLARE_TUNNEL_PARAM=none" >&2; exit 1; }
    TUNNEL_PARAM=""
else
    TUNNEL_PARAM="${CLOUDFLARE_TUNNEL_PARAM:-}"
    [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" && -z "$TUNNEL_PARAM" ]] && TUNNEL_PARAM="$TUNNEL_DEFAULT_PARAM"
    [[ -z "$TUNNEL_PARAM" || "$TUNNEL_PARAM" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "error: CLOUDFLARE_TUNNEL_PARAM must be an SSM parameter path like /a/b/c" >&2; exit 1; }
fi

# tokens are base64(json) - anything else is a copy/paste mistake (quotes, the whole
# `cloudflared service install ...` line, ...). Also what makes the JSON below safe to build.
[[ -z "$CLOUDFLARE_TUNNEL_TOKEN" || "$CLOUDFLARE_TUNNEL_TOKEN" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]] \
    || { echo "error: CLOUDFLARE_TUNNEL_TOKEN doesn't look like a tunnel token - pass only the token, not the whole install command" >&2; exit 1; }

# store the token if one was given, otherwise check the named parameter exists - either way
# fail here, before anything is launched or pushed, rather than on the instance
tunnel_prepare() {
    if [[ -z "$TUNNEL_PARAM" ]]; then
        # CLOUDFLARE_TUNNEL_PARAM=none: tunnel going off, so the instance no longer needs to read it
        [[ -n "$TUNNEL_SET" ]] && tunnel_revoke_read
        return 0
    fi
    # checked before anything is stored - without a profile the instance has no credentials to
    # read the token with, so storing it would only leave a secret behind for nothing
    [[ -n "$INSTANCE_PROFILE_NAME" ]] || { echo "error: the tunnel needs an instance profile to read its token - run 'run.sh ssm create' first" >&2; exit 1; }
    tunnel_store_token
    tunnel_grant_read
}

tunnel_store_token() {
    local exists
    exists=$(aws ssm describe-parameters \
        --region "$AWS_REGION" \
        --parameter-filters "Key=Name,Values=$TUNNEL_PARAM" \
        --query 'length(Parameters)' \
        --output text)

    if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
        [[ "$exists" == "1" ]] || { echo "error: SSM parameter $TUNNEL_PARAM not found - pass CLOUDFLARE_TUNNEL_TOKEN to store it" >&2; exit 1; }
        echo "Cloudflare tunnel: using token stored in $TUNNEL_PARAM"
        return 0
    fi

    # the value goes through a 0600 temp file, not --value, so it never shows up in `ps`
    local input
    input=$(umask 077; mktemp)
    if [[ "$exists" == "1" ]]; then
        printf '{"Name":"%s","Type":"SecureString","Overwrite":true,"Value":"%s"}' \
            "$TUNNEL_PARAM" "$CLOUDFLARE_TUNNEL_TOKEN" > "$input"
    else
        # tags can only be set on creation, not together with Overwrite
        printf '{"Name":"%s","Type":"SecureString","Value":"%s","Description":"Cloudflare tunnel token for %s %s","Tags":[{"Key":"Purpose","Value":"%s"},{"Key":"Name","Value":"%s"},{"Key":"Role","Value":"%s"}]}' \
            "$TUNNEL_PARAM" "$CLOUDFLARE_TUNNEL_TOKEN" "$TUNNEL_ROLE" "$NAME" "$Purpose" "$NAME" "$TUNNEL_ROLE" > "$input"
    fi

    aws ssm put-parameter --region "$AWS_REGION" --cli-input-json "file://$input" >/dev/null \
        || { rm -f "$input"; echo "error: couldn't store the tunnel token in $TUNNEL_PARAM" >&2; exit 1; }
    rm -f "$input"

    echo "Cloudflare tunnel: token stored in $TUNNEL_PARAM (SecureString)"
}

# the role behind the instance profile, looked up from the profile itself rather than trusting
# $ROLE_NAME in state - whatever the profile actually wraps is what the instance runs as
tunnel_instance_role() {
    [[ -n "$INSTANCE_PROFILE_NAME" ]] || return 0
    aws iam get-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --query 'InstanceProfile.Roles[0].RoleName' \
        --output text 2>/dev/null | grep -v '^None$' || true
}

# let the instance read its own token - idempotent (put-role-policy overwrites), so every
# create/sync just re-asserts it, including after the parameter was changed to a new path
tunnel_grant_read() {
    [[ -n "$TUNNEL_PARAM" ]] || return 0

    local role caller_arn partition account arn
    role=$(tunnel_instance_role)
    [[ -n "$role" ]] || { echo "error: instance profile $INSTANCE_PROFILE_NAME has no role attached" >&2; exit 1; }

    caller_arn=$(aws sts get-caller-identity --query Arn --output text)
    partition=$(cut -d: -f2 <<< "$caller_arn")
    account=$(cut -d: -f5 <<< "$caller_arn")
    # SSM parameter ARNs drop the name's leading slash: parameter/a/b, not parameter//a/b
    arn="arn:$partition:ssm:$AWS_REGION:$account:parameter/${TUNNEL_PARAM#/}"

    aws iam put-role-policy \
        --role-name "$role" \
        --policy-name "$TUNNEL_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ReadCloudflareTunnelToken\",\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",\"Resource\":\"$arn\"}]}" \
        || { echo "error: couldn't attach $TUNNEL_POLICY_NAME to role $role - the tunnel wouldn't be able to read its token" >&2; exit 1; }

    echo "Cloudflare tunnel: role $role may read $TUNNEL_PARAM (inline policy $TUNNEL_POLICY_NAME)"
}

tunnel_revoke_read() {
    local role
    role=$(tunnel_instance_role)
    [[ -n "$role" ]] || return 0
    if aws iam delete-role-policy --role-name "$role" --policy-name "$TUNNEL_POLICY_NAME" >/dev/null 2>&1; then
        echo "Removed inline policy $TUNNEL_POLICY_NAME from role $role"
    fi
}

# shell snippet for the instance: record which parameter to read (empty = tunnel off) and let
# the on-instance script (re)start or stop cloudflared accordingly
tunnel_commands() {
    echo "mkdir -p /etc/cloudflare-tunnel"
    echo "echo '$TUNNEL_PARAM' > /etc/cloudflare-tunnel/param"
    echo "/usr/local/sbin/cloudflare-tunnel.sh"
}

# `delete` removes this instance's read policy, and the token only if it's at the default path,
# i.e. one this script stored - a parameter named explicitly via CLOUDFLARE_TUNNEL_PARAM may be
# shared, so it's left alone
tunnel_delete_param() {
    tunnel_revoke_read

    if aws ssm delete-parameter --region "$AWS_REGION" --name "$TUNNEL_DEFAULT_PARAM" >/dev/null 2>&1; then
        echo "Deleted SSM parameter: $TUNNEL_DEFAULT_PARAM"
    fi
}
