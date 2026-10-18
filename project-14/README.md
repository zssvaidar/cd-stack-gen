# project-14 — four web apps with health checks, containerised for AWS

Four minimal HTTP services, one per stack, each with its own production `Dockerfile`.
They share the same conventions so one ECS/ALB setup fits all of them:

| App | Stack | Liveness | Readiness | Docker `HEALTHCHECK` |
|---|---|---|---|---|
| [`laravel-app/`](laravel-app/) | Laravel 13, PHP 8.4, Apache | `/health` (also Laravel's built-in `/up`) | `/health/ready` (DB connection) | `curl` |
| [`spring-app/`](spring-app/) | Spring Boot 4.1, Java 21 | `/actuator/health/liveness` | `/actuator/health/readiness` | `wget` on `/actuator/health` |
| [`csharp-app/`](csharp-app/) | ASP.NET Core, .NET 10 | `/health` | `/health/ready` (checks tagged `ready`) | `wget` |
| [`go-app/`](go-app/) | Go 1.24, stdlib only | `/health` | `/health/ready` (fails while draining) | binary's own `-healthcheck` flag (distroless image, no shell) |

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

## Tests

```sh
cd laravel-app && composer install && php artisan test
cd spring-app  && ./mvnw test
cd go-app      && go test ./...
cd csharp-app  && dotnet run     # then curl localhost:8080/health
```
