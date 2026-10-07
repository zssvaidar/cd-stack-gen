# project-12 — deploying bun-hydrate on ECS Fargate

Two ways to expose the web tier, a worker service for jobs/events, and RDS Postgres backing
both - continuing project-11's `run.sh <verb> <name> {create|delete}` shape, reusing its VPC,
app-tier subnet/SG, and egress gateway rather than provisioning a second network.

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=testing

# prerequisites, in project-11:
../project-11/run.sh network create
../project-11/run.sh ssm create
TIER=egress ../project-11/run.sh ami gw egress-gateway create
../project-11/run.sh egress gw create          # app-tier outbound internet access (ECR, CloudWatch, Cloudflare)

# build + push both images (see "Building the image" below), then:
./run.sh rds bun-hydrate create                # Postgres
./run.sh worker bun-hydrate create              # runs migrations, then the jobs/events worker
./run.sh tunnel bun-hydrate create              # OR: ./run.sh alb bun-hydrate create
```

## Does ECS need Caddy or a load balancer?

Not inherently - ECS is just an orchestrator (keeps containers running, restarts them, scales
replicas); it has no inbound traffic story of its own. Two real answers, both built here as
separate scripts rather than one script with a mode flag, since they're genuinely different
shapes (different task definitions, different networking, different teardown):

- **`run.sh tunnel`** - a `cloudflared` sidecar container in the same task as the app, talking
  to it over the task's own localhost. Every task replica connects to the *same* tunnel using
  the same token; Cloudflare's edge load-balances across however many connector replicas are
  up. No ALB, no public IP, no inbound security-group rule at all - tasks stay fully private.
  Matches how bun-hydrate already runs everywhere else in this project (see
  `cloud-init-cloudflared.sh` in the app's own repo).
- **`run.sh alb`** - an Application Load Balancer, the AWS-native answer. ECS
  registers/deregisters each task's IP in the target group automatically as the service
  scales - no Caddy or nginx needed, the ALB *is* the balancer. Tasks stay private; only the
  ALB itself is internet-facing, which means it needs two subnets in two distinct
  Availability Zones (a hard ALB requirement this script provisions for itself - see below).

Pick `tunnel` to match the rest of this project's existing bun-hydrate deploys, or `alb` for a
plain AWS-native HTTP endpoint with no Cloudflare dependency. Nothing stops both coexisting
(the cluster and ECR repo are shared), though normally you'd run one or the other.

## Why RDS, no Redis, and a separate worker

bun-hydrate's current feature set (`hydrate.features.json`) changed what "deploy this for
real" actually requires, since the project started:

- **RDS Postgres, not SQLite.** The default `DATABASE_URL` (`sqlite://:memory:`) is always
  re-migrated and loses all data on every restart - fine for `bun hydrate dev`, not for
  anything deployed. `run.sh rds` is a real managed Postgres instance.
- **No Redis.** `REDIS_URL` is optional - the installed job queue is `jobs:database` (stored in
  Postgres), not `jobs:redis`; Redis in `.env.example` is only for an optional demo chat
  fan-out feature the reference app doesn't need here. Skipped; add it later if you actually
  install a Redis-backed feature.
- **A separate worker service.** `jobs:database` is installed and already has jobs wired up
  (`cleanupExpiredSessionsJob`, `sendWelcomeEmailJob` per `hydrate.features.json`) - something
  has to run `bun dist/worker.js` to process them. `run.sh worker` is that service: no load
  balancer, no public exposure, nothing calls it from outside the cluster.
- **Storage left as `storage:local`** (the installed feature - not switched to `storage:s3`).
  Fine for a single task; if you scale the web service past one replica *and* the app
  actually exercises file uploads, `storage:local`'s directory isn't shared across tasks on
  Fargate. Switch the feature (`bun hydrate remove storage:local && bun hydrate add
  storage:s3`) and reuse `project-11/manage_s3.sh` for the bucket if that becomes a real need -
  not built here since it depends on whether uploads are actually used.

## Building the image

`docs/deploy/Dockerfile` in the bun-hydrate repo builds two things from one multi-stage build:
a `build` stage with the full repo and the `hydrate` CLI, and a slim runtime stage with just
`dist/`. The runtime stage is what the web/worker services run; the **build** stage is what
`run.sh worker`'s one-off migration task needs, since the CLI (`bun hydrate db:migrate`) isn't
present in the trimmed-down runtime image. Push both:

```bash
cd bun-hydrate
docker build --target build -f docs/deploy/Dockerfile -t $ECR_REPO:migrate .
docker build -f docs/deploy/Dockerfile -t $ECR_REPO:latest .

aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin $ECR_REPO
docker push $ECR_REPO:migrate
docker push $ECR_REPO:latest
```

`$ECR_REPO` is `<account-id>.dkr.ecr.<region>.amazonaws.com/${PURPOSE}-<name>` - `run.sh rds`
(or any of the `manage_ecs_*.sh` scripts, whichever runs first) creates that repository the
first time you run it; `aws ecr describe-repositories --repository-names ${PURPOSE}-<name>`
gets you the URI without waiting for a script run first if you want to push before any of them
have run.

## `run.sh rds <name> {create|delete}`

Postgres via RDS: a dedicated security group (port 5432 from project-11's `APP_SG` only -
whatever uses that SG, the ECS tasks included, can reach it; nothing else can), a random
master password, and the resulting `DATABASE_URL` stored as an SSM `SecureString` at
`/${PURPOSE}/<name>/database-url` - every `manage_ecs_*.sh` script reads it from there rather
than ever seeing the raw password.

RDS subnet groups need at least two Availability Zones, and project-11's subnets were all
created without an explicit AZ (nothing guarantees any two of them differ) - `create` checks,
and provisions its own second-AZ subnet (tagged `rds-standby`) if it needs one. This is a
*different* subnet from the one `run.sh alb` provisions for the same reason (tagged
`alb-standby`) - sharing one would mean trusting that RDS's second AZ and the ALB's first AZ
never coincide, which nothing here guarantees either; two independent subnets, each checked
against the one AZ it actually needs to differ from, costs one more `/24` and removes that
risk entirely.

`delete` removes the instance (`--skip-final-snapshot` - a portfolio/learning project tradeoff,
not what you'd want before a real production teardown), subnet group, security group, and SSM
parameter. The `rds-standby` subnet is left in place, harmless, and reused if you run `create`
again.

## `run.sh worker <name> {create|delete}`

1. Ensures the ECR repo, a `/ecs/${PURPOSE}-<name>` log group, a dedicated execution role
   (`AmazonECSTaskExecutionRolePolicy` plus `ssm:GetParameters` scoped to exactly
   `DATABASE_URL_PARAM`), and the ECS cluster (`${PURPOSE}-<name>` - shared with
   `run.sh tunnel`/`run.sh alb`, one cluster per app rather than one per script).
2. Registers a one-off task definition using the **`:migrate`** image and runs it
   (`aws ecs run-task`, then waits and checks its exit code) - `bun hydrate db:migrate`, per
   the docs' own recommendation over `MIGRATE_ON_START`. A nonzero exit stops here; the worker
   service is never touched.
3. Registers the worker task definition (the `:latest` image, `bun dist/worker.js`,
   `WORKER_PORT=3100` for its own container health check) and creates the service - or, if it
   already exists, deploys the new revision with `--force-new-deployment` (the common case:
   you'll re-run this on every new image push, not just once).

No load balancer, no dedicated security group - the worker uses `APP_SG` directly, same as
`run.sh tunnel`'s web containers, since neither needs any inbound rule at all.

`delete` scales the service to 0, waits, then deletes it - the cluster, ECR repo, execution
role, and log group are left in place (the cluster may still hold the web service; the rest
are persistent resources meant to survive a redeploy, not torn down with it).

## `run.sh tunnel <name> {create|delete}`

Builds the two-container task definition described above (`app` + `cloudflared`, no port
published) and creates/updates the `<name>-web-tunnel` service in the shared cluster - tasks in
project-11's `APP_SUBNET_ID`, using `APP_SG` directly, `assignPublicIp=DISABLED`.

Needs a Cloudflare Tunnel token at `/cloudflare/<name>/tunnel-token` (SSM `SecureString`,
override the path with `CLOUDFLARE_TOKEN_PARAM`) - the same parameter convention
`cloud-init-cloudflared.sh` already uses for bun-hydrate's EC2 deploys, just read by the ECS
execution role instead of an instance's IAM role:

```bash
aws ssm put-parameter --name /cloudflare/bun-hydrate/tunnel-token --type SecureString \
    --value "$(cloudflared tunnel token <tunnel-name>)"
```

`delete` scales the service to 0 and removes it; same persistent resources left in place as
`run.sh worker`.

## `run.sh alb <name> {create|delete}`

1. Same ECR/log-group/execution-role/cluster setup as `run.sh worker`, with its own role
   (`ssm:GetParameters` on `DATABASE_URL_PARAM` only - no tunnel token, it doesn't need one).
2. Ensures its own second-AZ subnet (see `run.sh rds` above for why it's not shared with
   RDS's), verified against `BASTION_SUBNET_ID`'s AZ specifically.
3. Two dedicated security groups: one for the ALB (port 80 from `0.0.0.0/0`), one for the
   tasks (port 3000 from *only* the ALB's security group - not the broader "anything in the
   VPC" rule `manage_egress_instance.sh` needs for NAT, since nothing else should reach these
   tasks directly).
4. An internet-facing ALB across `BASTION_SUBNET_ID` and the new AZ2 subnet, a target group
   (`target-type ip`, health check on `/ready` - readiness, not just liveness, matching
   `docs/deploy/docker-compose.yml`'s own health-check convention), and an HTTP listener on
   port 80.
5. Registers the task definition (the `:latest` image, port 3000 published) and
   creates/updates the `<name>-web-alb` service with the target group wired in - tasks in
   `APP_SUBNET_ID` using the dedicated task security group, `assignPublicIp=DISABLED`.

```bash
./run.sh alb bun-hydrate create
# ALB DNS printed at the end, or: aws elbv2 describe-load-balancers --names $PURPOSE-bun-hydrate-alb
```

`delete` scales the service to 0 and removes it, then the listener, the ALB itself (waited on,
since deletion is asynchronous), the target group, and both security groups - in that order,
since each depends on the one before it being gone first. The cluster, ECR repo, execution
role, log group, and `alb-standby` subnet are left in place.

## Everything this reuses from project-11

- `APP_SUBNET_ID`/`APP_SG` - where every ECS task actually runs; private, no public IP.
- The egress gateway (`../project-11/run.sh egress gw create`) - Fargate still needs outbound
  reachability to pull images from ECR, write to CloudWatch, and (for `run.sh tunnel`) reach
  Cloudflare's edge, and the app subnet has no NAT Gateway of its own.
- `BASTION_SUBNET_ID` - the one public, IGW-routed subnet `run.sh alb` puts the ALB's first AZ
  in (its second AZ is a subnet this script provisions itself, see above).
- `VPC_ID`/`PUBLIC_RT_ID` - for provisioning the AZ2 subnets `run.sh rds`/`run.sh alb` each need.

None of `project-12`'s own `run.sh` verbs provision any of this - run `../project-11/run.sh
network create` (and `egress`) first, every time, under a new `PURPOSE`.
