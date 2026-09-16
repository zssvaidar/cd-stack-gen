# project-9 — PHP 8 build/test/deploy, dual web servers, Vault secret injection

Continues this repo's `project-N` series (project-8 is the Jenkins+Vault+AWS-IAM
plumbing this project's scripts plug into). Scope: a mock Composer project to build
and test against, a configurable PHP 8 + php.ini setup, both nginx and Apache as
front ends for the same php-fpm container (either works for a real Laravel app
unmodified - see below), idempotent build/test/deploy scripts, and Vault-based
secret injection into the container at start, not bake time.

## Layout

```
app/                        mock Composer project (build/test target)
  composer.json / composer.lock
  src/Calculator.php, src/HealthCheck.php
  tests/*Test.php           phpunit, run via `composer test`
  public/index.php          front controller - same entry point Laravel uses
docker/
  php/
    Dockerfile               multi-stage: composer install (no-dev) -> php8-fpm-alpine runtime
    php.ini                  production-leaning overrides, ARG PHP_VERSION selects the 8.x line
    conf.d/opcache-{prod,dev}.ini   switched by docker-entrypoint.sh based on APP_ENV
    www.conf                 php-fpm pool: clear_env=no so Vault-injected env reaches the app
    docker-entrypoint.sh     fetches secrets from Vault, execs php-fpm - see docs/
  nginx/
    Dockerfile, default.conf   fastcgi_pass to php:9000, Laravel-style rewrite
  apache/
    Dockerfile, laravel.conf   mod_proxy_fcgi to the SAME php:9000 - not mod_php
docker-compose.yml           php + nginx by default; `--profile apache` adds apache on :8081
scripts/
  build.sh                    composer install/validate, then docker build (skips work already done)
  test.sh                     lint + phpunit, then a container smoke test against both servers
  deploy.sh                   idempotent rollout (local or over SSH) with pre-flight config checks
  lib/idempotent.sh            shared "has this already happened?" checks used by all three
docs/
  vault-secret-injection.md   the actual answer to "how do I inject Vault secrets into this" + tradeoffs
```

## Why both a mock app and "works with real Laravel" throughout

The build/test/deploy pipeline needs *something* real to build and test now, without
waiting on an actual Laravel app existing yet - `app/` is that stand-in: a real
`composer.json`, real PHPUnit tests, a real front controller at `public/index.php`.
Every other file (both Dockerfiles, both server configs, `www.conf`, `php.ini`) is
written so that swapping `app/` for an actual Laravel install (with `artisan`,
`bootstrap/cache/`, `storage/`) needs no changes to `docker/` or `docker-compose.yml` -
only uncommenting the `storage`/`bootstrap/cache` permission lines called out in
`docker/php/Dockerfile`.

## Build + test

```bash
cd project-9-php-laravel-cd
cp .env.example .env                 # everything works with VAULT_* left blank

./scripts/build.sh                   # composer install/validate + build php/nginx/apache images
./scripts/test.sh                    # phpunit + lint, then a container smoke test on :8080 and :8081
./scripts/test.sh --unit-only        # phpunit + lint only, no docker required

# or, without the scripts, directly:
cd app && composer install && composer test
```

Verified locally in this environment: `composer validate --strict` passes,
`composer run lint` (`php -l` across every tracked file) passes, and `composer run
test` runs 5 PHPUnit assertions across 3 tests, all green.

## Run it

```bash
docker compose up --build                    # php + nginx on http://localhost:8080
docker compose --profile apache up --build    # also apache on http://localhost:8081

curl http://localhost:8080/           # {"app": "project-9-mock-app", "ok": true}
curl http://localhost:8080/healthz    # nginx's own liveness, bypasses php-fpm
curl http://localhost:8081/           # same app, through Apache + mod_proxy_fcgi instead
```

## Configuring PHP 8

- `PHP_VERSION` build arg (default `8.3`) selects the `php:${PHP_VERSION}-fpm-alpine`
  base for both build and runtime stages - `docker build --build-arg PHP_VERSION=8.2`
  or `PHP_VERSION=8.2 docker compose up --build` targets a different 8.x line with no
  file edits.
- Engine settings live in `docker/php/php.ini` (loaded as `zz-app.ini`, after the
  base image's own defaults, so it wins). Pool/process settings (workers, listen
  socket, `clear_env`) are separate, in `docker/php/www.conf` - see that file's header
  comment for why they're split.
- `opcache.validate_timestamps` flips between the two `docker/php/conf.d/opcache-*.ini`
  files based on `APP_ENV`, handled by `docker-entrypoint.sh` at container start.

## Deploying

```bash
./scripts/deploy.sh nginx                        # this machine
./scripts/deploy.sh apache ec2-user@10.0.1.23     # over SSH to an EC2 host
```

Every step in `deploy.sh` checks state before acting, per your ask for "always check
if something is already set up" - see `scripts/lib/idempotent.sh` for the checks
(docker already installed, port already ours vs. actually in use by something else,
config syntax valid before rollout, health-checked before declaring success). Full
list of what it does and doesn't do (e.g. no automatic rollback - portfolio scope,
matches project-8/project-9's siblings in the ecom1 repo) is in `deploy.sh`'s own
header comment.

## Vault secrets -> container

Short answer: `docker/php/docker-entrypoint.sh` fetches them from Vault at container
start and exports them into the process the app runs as - never baked into the image,
never passed as `docker run -e`. Full reasoning, the sidecar alternative, and the ECS
angle are in [`docs/vault-secret-injection.md`](docs/vault-secret-injection.md).
