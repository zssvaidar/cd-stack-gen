# shellcheck shell=bash
# Sourced by run.sh with ENV_NAME, APP_NAME, ACTION set (and the creator creds active):
#   run.sh secrets <env> <app> {push|list|pull|delete}
#
# wrapper/<env>/<app>/.env  <->  SSM Parameter Store, one SecureString per variable:
#   $SSM_PREFIX/<env>/<app>/<KEY>        e.g. /cd-stack-gen/dev/laravel/DB_PASSWORD
# so infrastructure can refer to each one by name - an ECS task definition's
# secrets[].valueFrom, an instance fetching its path at boot, a Terraform data source.
#
# The .env is parsed, never sourced/executed: KEY=value lines, optional `export `, # comments,
# blank lines, and single- or double-quoted values, which may span several lines (a PEM key).
# Inside double quotes \n, \" and \\ are unescaped, as docker compose does; single quotes are
# literal. Unquoted values end at " #".
#
# Settings (environment):
#   SSM_PREFIX   default /cd-stack-gen
#   KMS_KEY_ID   KMS key for the SecureStrings; default the account's aws/ssm key
#   PRUNE=true   push also deletes parameters under the path that are no longer in the .env
#   FORCE=true   delete without asking
# Needs: aws cli v2, jq.

SSM_PREFIX="${SSM_PREFIX:-/cd-stack-gen}"
KMS_KEY_ID="${KMS_KEY_ID:-}"
PRUNE="${PRUNE:-false}"
FORCE="${FORCE:-false}"

die() { echo "manage_secrets: $*" >&2; exit 1; }
log() { echo "manage_secrets: $*" >&2; }

command -v jq >/dev/null || die "jq is required"

# Path segments only - no slashes or dots, so a name can never reach outside its own path.
[[ "$ENV_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "env must be lowercase letters, digits and dashes: '$ENV_NAME'"
[[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "app must be lowercase letters, digits and dashes: '$APP_NAME'"
[[ "$SSM_PREFIX" =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || die "SSM_PREFIX must look like /name or /name/sub: '$SSM_PREFIX'"

SSM_PATH="$SSM_PREFIX/$ENV_NAME/$APP_NAME"
ENV_FILE="wrapper/$ENV_NAME/$APP_NAME/.env"

# --------------------------------------------------
# .env parsing. Prints KEY<NUL>VALUE<NUL> per variable, in file order (later duplicates win
# when read back into the arrays below).
# --------------------------------------------------

# Does $1 (a quoted value with its opening quote already removed) end with the closing quote $2,
# optionally followed by whitespace and a # comment? A \" doesn't count as closing.
closes() {
    local value=$1 q=$2
    if [[ "$q" == '"' ]]; then
        [[ "$value" =~ ^(.*[^\\]|)\"[[:space:]]*(#.*)?$ ]]
    else
        [[ "$value" =~ ^(.*)\'[[:space:]]*(#.*)?$ ]]
    fi
}

parse_env_file() {
    local file=$1 line key value q n=0 start

    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die "$file:$n: expected KEY=value"
        key=${BASH_REMATCH[2]}
        value=${BASH_REMATCH[3]}
        start=$n

        case "$value" in
            \"*) q='"' ;;
            \'*) q="'" ;;
            *) q='' ;;
        esac

        if [[ -n "$q" ]]; then
            value=${value:1}
            until closes "$value" "$q"; do
                IFS= read -r line || die "$file:$start: $key: unterminated $q quote"
                n=$((n + 1))
                value+=$'\n'"${line%$'\r'}"
            done
            value=${BASH_REMATCH[1]}
            if [[ "$q" == '"' ]]; then
                # \\ first via a placeholder, so \\n stays a literal backslash + n
                value=${value//\\\\/$'\001'}
                value=${value//\\n/$'\n'}
                value=${value//\\\"/\"}
                value=${value//$'\001'/\\}
            fi
        else
            # unquoted: an inline comment starts at whitespace + #
            [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]] && value=${BASH_REMATCH[1]}
            [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]*$ ]] && value=${BASH_REMATCH[1]}
        fi

        printf '%s\0%s\0' "$key" "$value"
    done < "$file"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Name<TAB>base64(value) of every parameter under SSM_PATH (decrypted - stays in this process).
remote_params() {
    aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$SSM_PATH" --recursive \
        --with-decryption --output json \
        | jq -r '.Parameters[] | [.Name, (.Value | @base64)] | @tsv'
}

# --------------------------------------------------
# Actions
# --------------------------------------------------

push() {
    [[ -f "$ENV_FILE" ]] || die "no $ENV_FILE (= project-9/wrapper/$ENV_NAME/$APP_NAME/.env) - copy its .env.example and fill it in"
    # asked from the file's real directory: git won't take a path through the wrapper symlink
    local env_dir
    env_dir=$(cd "$(dirname "$ENV_FILE")" && pwd -P)
    if git -C "$env_dir" ls-files --error-unmatch .env >/dev/null 2>&1; then
        die "$ENV_FILE is tracked by git - remove it from the index (git rm --cached) and rotate what's in it first"
    fi

    local keys=() values=() key value i
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
        for i in ${keys[@]+"${!keys[@]}"}; do
            [[ "${keys[$i]}" == "$key" ]] && { unset 'keys[i]' 'values[i]'; log "warning: $key set twice, the later one wins"; }
        done
        keys+=("$key")
        values+=("$value")
    done < <(parse_env_file "$ENV_FILE")
    [[ ${#keys[@]} -gt 0 ]] || die "$ENV_FILE has no variables"
    keys=("${keys[@]}")
    values=("${values[@]}")

    local remote_names=() remote_values=() name rv
    while IFS=$'\t' read -r name rv; do
        remote_names+=("$name")
        remote_values+=("$rv")
    done < <(remote_params)

    local tmp created=0 updated=0 unchanged=0 skipped=0 existing
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    chmod 600 "$tmp"

    for i in "${!keys[@]}"; do
        key=${keys[$i]}
        value=${values[$i]}
        name="$SSM_PATH/$key"

        if [[ -z "$value" ]]; then
            log "skip    $key (empty - Parameter Store can't hold an empty value)"
            skipped=$((skipped + 1))
            continue
        fi

        existing=""
        for rv in ${remote_names[@]+"${!remote_names[@]}"}; do
            [[ "${remote_names[$rv]}" == "$name" ]] && existing=${remote_values[$rv]}
        done
        if [[ -n "$existing" && "$existing" == "$(b64 "$value")" ]]; then
            unchanged=$((unchanged + 1))
            continue
        fi

        # Value via a 0600 JSON file, not --value: keeps it out of the process list, and the CLI
        # would otherwise try to load a value starting with file:// as a file.
        # Intelligent-Tiering: standard (free) up to 4 KB, advanced only for values that need it.
        jq -n --arg n "$name" --arg v "$value" --arg k "$KMS_KEY_ID" \
            '{Name: $n, Value: $v, Type: "SecureString", Overwrite: true, Tier: "Intelligent-Tiering"}
             + (if $k == "" then {} else {KeyId: $k} end)' > "$tmp"
        aws ssm put-parameter --region "$AWS_REGION" --cli-input-json "file://$tmp" --output text >/dev/null

        if [[ -n "$existing" ]]; then
            log "update  $name"
            updated=$((updated + 1))
        else
            # tags can't be combined with Overwrite, so they're added once, on create
            aws ssm add-tags-to-resource --region "$AWS_REGION" --resource-type Parameter --resource-id "$name" \
                --tags "Key=Project,Value=project-15" "Key=Environment,Value=$ENV_NAME" "Key=App,Value=$APP_NAME"
            log "create  $name"
            created=$((created + 1))
        fi
    done
    rm -f "$tmp"
    trap - EXIT

    # parameters under the path that the .env no longer has
    local stale=() found
    for name in ${remote_names[@]+"${remote_names[@]}"}; do
        found=false
        for key in "${keys[@]}"; do
            [[ "$name" == "$SSM_PATH/$key" ]] && found=true
        done
        [[ "$found" == true ]] || stale+=("$name")
    done
    if [[ ${#stale[@]} -gt 0 ]]; then
        if [[ "$PRUNE" == true ]]; then
            delete_names "${stale[@]}"
        else
            log "not in $ENV_FILE (kept - PRUNE=true deletes them):"
            printf '  %s\n' "${stale[@]}" >&2
        fi
    fi

    log "$SSM_PATH: $created created, $updated updated, $unchanged unchanged, $skipped skipped"
}

list() {
    aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$SSM_PATH" --recursive --output json \
        | jq -r '.Parameters | sort_by(.Name)[] | "\(.Name)\t\(.Type)\tv\(.Version)\t\(.LastModifiedDate)"'
}

# KEY='value' - single quotes, ' as '\'', so `set -a; source <(...)` never expands or runs
# anything in a value, and multi-line values stay one variable.
pull() {
    aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$SSM_PATH" --recursive \
        --with-decryption --output json \
        | jq -r --arg p "$SSM_PATH/" '.Parameters | sort_by(.Name)[]
              | (.Name | ltrimstr($p)) + "=" + "'"'"'" + (.Value | gsub("'"'"'"; "'"'"'\\'"'"''"'"'")) + "'"'"'"'
}

delete_names() {
    local batch=() name
    for name in "$@"; do
        batch+=("$name")
        if [[ ${#batch[@]} -eq 10 ]]; then # DeleteParameters takes at most 10
            aws ssm delete-parameters --region "$AWS_REGION" --names "${batch[@]}" --output text >/dev/null
            batch=()
        fi
        log "delete  $name"
    done
    if [[ ${#batch[@]} -gt 0 ]]; then
        aws ssm delete-parameters --region "$AWS_REGION" --names "${batch[@]}" --output text >/dev/null
    fi
}

delete() {
    local names=() name answer
    while IFS= read -r name; do
        names+=("$name")
    done < <(aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$SSM_PATH" --recursive --output json \
        | jq -r '.Parameters[].Name')
    [[ ${#names[@]} -gt 0 ]] || { log "nothing under $SSM_PATH"; return 0; }

    if [[ "$FORCE" != true ]]; then
        printf '  %s\n' "${names[@]}" >&2
        read -r -p "delete these ${#names[@]} parameters? type '$ENV_NAME/$APP_NAME' to confirm: " answer
        [[ "$answer" == "$ENV_NAME/$APP_NAME" ]] || die "not confirmed - nothing deleted"
    fi
    delete_names "${names[@]}"
}

case "$ACTION" in
    push) push ;;
    list) list ;;
    pull) pull ;;
    delete) delete ;;
esac
