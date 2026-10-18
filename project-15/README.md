# project-15 — app secrets: `.env` files ⇄ SSM Parameter Store

One place for each app's important values (database credentials, `APP_KEY`, API tokens): a
gitignored `.env` next to the shared creator credentials, pushed into SSM Parameter Store as one
`SecureString` per variable. Infrastructure then refers to each value **by name**. That can be an
ECS task definition's `secrets`, a Terraform data source, or an instance reading its path at boot.
The values themselves never go into git, an AMI, user_data or Terraform state.

```
project-9/wrapper/<env>/<app>/.env   ──push──▶  /cd-stack-gen/<env>/<app>/<KEY>   (SecureString)
   (gitignored, yours)              ◀──pull──      e.g. /cd-stack-gen/dev/laravel/DB_PASSWORD
```

## Usage

```bash
cd project-15
cp wrapper/dev/laravel/.env.example wrapper/dev/laravel/.env    # = project-9/wrapper/dev/laravel/.env
$EDITOR wrapper/dev/laravel/.env

./run.sh secrets dev laravel push      # create/update one SecureString per variable
./run.sh secrets dev laravel list      # names, versions, dates - never values
./run.sh secrets dev laravel pull      # KEY='value' lines on stdout
./run.sh secrets dev laravel delete    # everything under the path (asks first)
```

- `push` is idempotent. Unchanged values are skipped, so a re-run makes no writes and parameter
  versions only move when a value changes. It reports keys that are in SSM but no longer in the
  file. `PRUNE=true` deletes those.
- Empty values are skipped, because Parameter Store can't hold an empty string.
- Values up to 4 KB are standard parameters, which are free. Bigger ones, such as a long PEM key,
  become advanced parameters automatically (Intelligent-Tiering).
- `SSM_PREFIX` changes `/cd-stack-gen`. `KMS_KEY_ID` encrypts with your own key instead of the
  account's `aws/ssm` key. `FORCE=true` skips `delete`'s confirmation. `AWS_REGION` defaults to
  `ap-northeast-1`, as in the rest of the stack.
- `run.sh` uses the same `wrapper/` creator credentials as project-11/12/13 (`wrapper/config/.env`).
  Its own status output goes to stderr, so `pull` can be redirected cleanly.

Needs the AWS CLI v2 and `jq`.

### The `.env` format

It's parsed, never sourced, so nothing in it can execute:

```bash
# comments and blank lines are fine
APP_NAME=My App                 # unquoted: ends at " #", surrounding spaces trimmed
export DB_HOST=db.internal      # a leading `export` is ignored
DB_PASSWORD="p@ss#word"         # double quotes: \n, \" and \\ are unescaped, as docker compose does
LITERAL='$HOME stays $HOME'     # single quotes: taken literally
ATLANTIS_GH_APP_KEY="-----BEGIN RSA PRIVATE KEY-----
MIIEow...
-----END RSA PRIVATE KEY-----"  # quoted values can span lines
```

### Safety rails

- `project-9/wrapper/.gitignore` ignores `<env>/<app>/.env` (and `.env.*` backups). Only
  `.env.example` templates are committed.
- `push` refuses to run if the `.env` is tracked by git anyway. If that ever happens, untrack it and
  rotate the values, because they're in the history.
- `env` and `app` must be lowercase letters, digits and dashes. A name like `../prod` can't escape
  its own path.
- Values go to the AWS CLI through a `0600` temp file, not `--value`. That keeps them out of the
  process list, and a value starting with `file://` isn't loaded as a file.

## Using them in infrastructure

### Terraform: ECS task definitions

This uses the same pattern as plain `env_variables` next to `secret_variables`. Non-secret config
stays in Terraform. Secrets are referenced by ARN, and ECS injects the values when it starts the task:

```hcl
locals {
  ssm_path = "/cd-stack-gen/${var.env}/laravel"   # what `run.sh secrets <env> laravel push` writes

  env_variables = {
    APP_ENV       = "production"
    DB_CONNECTION = "mysql"
    DB_PORT       = "3306"
  }

  secret_variables = [
    "APP_KEY",
    "DB_HOST",
    "DB_USERNAME",
    "DB_PASSWORD",
  ]

  secrets = {
    for item in local.secret_variables :
    item => data.aws_ssm_parameter.environment[item].arn
  }
}

data "aws_ssm_parameter" "environment" {
  for_each = toset(local.secret_variables)

  name            = "${local.ssm_path}/${each.value}"
  with_decryption = false # only the ARN is used - keeps the plaintext out of Terraform state
}

# in the container definition:
#   environment = [for k, v in local.env_variables : { name = k, value = v }]
#   secrets     = [for k, arn in local.secrets : { name = k, valueFrom = arn }]
```

`with_decryption = false` matters. With the default, the decrypted values land in the state file.
The data source also fails at plan time if a name is missing from SSM, which is how you catch a
`.env` you forgot to push before deploying.

The task **execution role** needs to read the path:

```hcl
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_path}/*"]
  }
  # only if you pushed with KMS_KEY_ID - the default aws/ssm key needs no extra grant
  # statement {
  #   actions   = ["kms:Decrypt"]
  #   resources = [var.kms_key_arn]
  # }
}
```

### docker compose, locally

For a compose file that passes variables through by name, such as
`environment: [ATLANTIS_GH_APP_ID, ...]`, load the values into the shell first:

```bash
set -a
source <(../project-15/run.sh secrets dev atlantis pull)
set +a
docker compose up
```

`pull` single-quotes every value (`'` becomes `'\''`). Sourcing it never expands or runs anything
inside a value, and multi-line values (keys, certificates) stay intact.

### EC2 instances (project-13's AMIs)

The instance role gets `ssm:GetParametersByPath` on `/cd-stack-gen/<env>/<app>/*`, and a unit runs
at boot, before the app starts. That unit calls `get-parameters-by-path --with-decryption` and
writes the values to the app's env file: `/etc/<app>/app.env`, or `/etc/laravel-app/app.env` for
Laravel. The apps already read those files. This isn't wired in yet; it's the next step for the
project-14 images.

## Rotating a value

Edit the `.env` and `push` again. Running services keep the old value until they restart:
re-deploy the ECS service (`aws ecs update-service --force-new-deployment`) or restart or replace the
instance. Parameter Store keeps a version history, so `list` shows which version is current.
