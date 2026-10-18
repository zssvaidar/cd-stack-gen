#!/bin/sh
# Config comes from the environment (ECS task definition / Secrets Manager),
# so caches are built at start, not at image build time.
set -e

if [ -z "$APP_KEY" ]; then
  echo "entrypoint: APP_KEY is not set (generate with: php artisan key:generate --show)" >&2
  exit 1
fi

if [ "${DB_CONNECTION:-sqlite}" = "sqlite" ]; then
  db="${DB_DATABASE:-database/database.sqlite}"
  [ -f "$db" ] || touch "$db"
  # Container-local SQLite starts empty; sessions/cache tables live in it.
  RUN_MIGRATIONS=true
fi

php artisan config:cache
php artisan route:cache
php artisan view:cache

if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
  php artisan migrate --force
fi

exec "$@"
