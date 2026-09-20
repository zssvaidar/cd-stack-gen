# wrapper

Small shared shell library for the single-file `create`/`destroy` orchestrator scripts in this
stack (see `../../project-10/ssm-manage`). Not meant to be copied - symlink it into a script's
own directory instead, so there's one copy of `set_root`/`whoami`/`unset_aws` for everything to
share:

```bash
cd project-10/some-new-orchestrator
ln -s ../../project-9/wrapper wrapper
```

Then in the script itself:

```bash
source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami
```

## `common/init.sh`

- `unset_aws` — clears `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`
  from the environment. Run this before `set_root`: an env var exported earlier in the same
  shell (e.g. short-lived Vault-issued creds from a different project) silently wins over
  whatever `set_root` configures, since the AWS CLI's credential chain checks env vars first.
- `set_root` — points the AWS CLI's default profile at `$AWS_ACCESS_KEY_ID_CREATOR` /
  `$SECRET_ACCESS_KEY_CREATOR` from `config/.env`, same creator credentials used across this
  stack (see `project-8/aws-perm-generator`).
- `whoami` — `aws sts get-caller-identity`, to confirm the above actually took effect before
  a script goes on to create or destroy real resources.

## `config/.env.example`

Copy to `config/.env` (gitignored) and fill in the creator credentials:

```
AWS_ACCESS_KEY_ID_CREATOR=
SECRET_ACCESS_KEY_CREATOR=
```
