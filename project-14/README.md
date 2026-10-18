# project-14 — four web apps with health checks, containerised for AWS

Four minimal HTTP services, one per stack, each with its own production `Dockerfile`.
They share the same conventions so one ECS/ALB setup fits all of them:

| App | Stack | Liveness | Readiness | Docker `HEALTHCHECK` |
|---|---|---|---|---|
| [`laravel-app/`](laravel-app/) | Laravel 13, PHP 8.4, Apache | `/health` (also Laravel's built-in `/up`) | `/health/ready` (DB connection) | `curl` |
| [`spring-app/`](spring-app/) | Spring Boot 4.1, Java 21 | `/actuator/health/liveness` | `/actuator/health/readiness` | `wget` on `/actuator/health` |
| [`csharp-app/`](csharp-app/) | ASP.NET Core, .NET 10 | `/health` | `/health/ready` (checks tagged `ready`) | `wget` |
| [`go-app/`](go-app/) | Go 1.26, stdlib + Prometheus client | `/health` | `/health/ready` (fails while draining) | binary's own `-healthcheck` flag (distroless image, no shell) |

Shared conventions:

- Listens on `$PORT`, default **8080**; containers run as a **non-root** user.
- Health responses are JSON `{"status":"UP"}`, HTTP 200 when healthy, 503 when not.
- Logs go to stdout/stderr (CloudWatch via the `awslogs` driver); health probes are not access-logged where the server logs requests.
- Forwarded headers from an ALB are honoured (client IP / scheme).

## Build and run locally

```sh
cd project-14/<app>
docker build -t <app> .
docker run --rm -p 8080:8080 <app>          # laravel-app also needs -e APP_KEY=...
curl localhost:8080/health                   # spring-app: /actuator/health
```

For Graviton (arm64) tasks build with `docker buildx build --platform linux/arm64 ...`.

## Deploying on AWS (ECS Fargate + ALB)

1. Push each image to ECR:
   ```sh
   aws ecr create-repository --repository-name <app>
   aws ecr get-login-password | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
   docker tag <app> <acct>.dkr.ecr.<region>.amazonaws.com/<app>:latest
   docker push <acct>.dkr.ecr.<region>.amazonaws.com/<app>:latest
   ```
2. Task definition: container port `8080`. ECS ignores the image's `HEALTHCHECK`, so copy it
   into the container definition's `healthCheck` if you want ECS-level checks, e.g. for Go:
   `"command": ["CMD", "/go-app", "-healthcheck"]`.
3. ALB target group: target type `ip`, port `8080`, health check path = the app's
   readiness path from the table above, success code `200`.

### Laravel specifics

- `APP_KEY` is required — the entrypoint refuses to start without it. Generate one with
  `php artisan key:generate --show` and pass it from Secrets Manager / SSM.
- Without DB settings it uses a container-local SQLite file and migrates it on start (fine for a
  demo, data is lost with the task). For RDS set `DB_CONNECTION=mysql|pgsql`, `DB_HOST`,
  `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, and `RUN_MIGRATIONS=true` on one task
  (or run `php artisan migrate --force` as a one-off task).
- Config, routes and views are cached at container start, after the task's env is applied.

## Plain EC2 instead of containers: AMIs

Each app also has a Packer provisioner script in
[`project-11/ami-scripts/`](../project-11/ami-scripts/) (project-13 reads the same folder through its
`ami-scripts` symlink). The script builds the app on the builder instance and runs it under systemd
behind Caddy on `:80`. It smoke-tests the app before the snapshot.

| App | Script | Bake |
|---|---|---|
| laravel-app | `laravel.sh` | `run.sh ami laravel-app laravel create` |
| spring-app | `spring.sh` | `run.sh ami spring-app spring create` |
| csharp-app | `csharp.sh` | `run.sh ami csharp-app csharp create` |
| go-app | `go.sh` | `run.sh ami go-app go create` |

By default they fetch this repo from GitHub at `master`. Override that with
`PROVISION_ENV="APP_REF=<branch>"`, or give an `APP_SOURCE=s3://...` tarball or an
`APP_GIT_TOKEN_PARAM` for a private repo. See the ami-scripts README for the details, including how
the Laravel image generates its `APP_KEY` on first boot.

## Monitoring: Grafana, Mimir, Loki and Alloy

```
app instance                                       monitoring instance (grafana.sh)
  Alloy ─ host metrics, app /metrics, ──:9009──▶  Mimir  ─┐
          health probe                                     ├─▶ Grafana :3000
        ─ journal (app, Caddy) ─────────:3100──▶  Loki   ─┘     "project-14 apps" dashboard
```

Everything lives in [`monitoring/`](monitoring/) and is installed by the AMI scripts:

| Path | What |
|---|---|
| `monitoring/alloy/config.alloy` | the one Alloy config every instance runs, parameterised by env vars |
| `monitoring/alloy/install.sh` | installs Alloy from rpm.grafana.com, off until `/etc/alloy/endpoint.env` exists |
| `monitoring/mimir/config.yml` | single-node Mimir, local filesystem, 30-day retention |
| `monitoring/loki/config.yml` | single-node Loki, local filesystem, 14-day retention |
| `monitoring/grafana/` | provisioned data sources (`mimir`, `loki`) and dashboards |

Each app exposes Prometheus metrics for Alloy to scrape on loopback:

| App | Metrics endpoint | Request metrics |
|---|---|---|
| spring-app | `/actuator/prometheus` (Micrometer) | `http_server_requests_seconds` (with histogram buckets) |
| go-app | `/metrics` (`client_golang`) | `http_server_requests_seconds`, same name as Spring's |
| csharp-app | `/metrics` (`prometheus-net`) | `http_request_duration_seconds` |
| laravel-app | php-fpm's status page as OpenMetrics, on Caddy `127.0.0.1:9180/metrics` (AMI only) | `phpfpm_accepted_connections`, `phpfpm_active_processes`, ... |

On the AMIs, Caddy returns 404 for those paths on `:80`. In the containers nothing sits in front of
the app, so keep `/metrics` and `/actuator/prometheus` off the public ALB (listener rules), or scrape
them from an Alloy sidecar.

Deploy order per environment:

1. Bake the images once: `run.sh ami monitoring grafana create`, plus the four app images.
2. Launch the monitoring instance and note its private IP. Its security group allows 9009 and 3100 from
   the VPC, and 3000 from wherever you open Grafana.
3. Launch the app instances with user-data that writes `/etc/alloy/endpoint.env`:
   ```yaml
   #cloud-config
   write_files:
     - path: /etc/alloy/endpoint.env
       content: |
         MONITORING_HOST=10.10.1.23
         ENVIRONMENT=dev
   ```
   On an instance that's already running, use `sudo alloy-endpoint 10.10.1.23 dev`.
4. Open Grafana and log in as `admin`. The password is in `/etc/grafana/admin.env` on the monitoring
   instance (`sudo cat` it over SSM). The dashboard is under *project-14 → project-14 apps*.

## Tests

```sh
cd laravel-app && composer install && php artisan test
cd spring-app  && ./mvnw test
cd go-app      && go test ./...
cd csharp-app  && dotnet run     # then curl localhost:8080/health
```
