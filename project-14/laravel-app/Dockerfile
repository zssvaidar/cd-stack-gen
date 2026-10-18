# syntax=docker/dockerfile:1
# Laravel on php-apache, single container (ECS/Fargate, App Runner, EC2).
# Build:  docker build -t laravel-app .
# Run:    docker run -p 8080:8080 -e APP_KEY=base64:... laravel-app

ARG PHP_VERSION=8.4

# --- composer deps (no dev) ---------------------------------------------------
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --no-interaction --prefer-dist
COPY . .
RUN composer dump-autoload --no-dev --optimize --classmap-authoritative

# --- frontend assets (vite) ---------------------------------------------------
FROM node:22-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY resources ./resources
COPY vite.config.js ./
COPY public ./public
RUN npm run build

# --- runtime -----------------------------------------------------------------
FROM php:${PHP_VERSION}-apache AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends libicu-dev libzip-dev libpq-dev libsqlite3-dev curl \
 && docker-php-ext-install -j"$(nproc)" intl zip opcache pdo_mysql pdo_pgsql pdo_sqlite \
 && rm -rf /var/lib/apt/lists/*

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf

# Non-root user cannot bind :80, so Apache listens on $PORT (default 8080).
ENV PORT=8080 \
    APP_ENV=production \
    APP_DEBUG=false \
    LOG_CHANNEL=stderr \
    APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri 's/^Listen 80$/Listen ${PORT}/' /etc/apache2/ports.conf \
 && a2enmod rewrite headers remoteip

WORKDIR /var/www/html
COPY --from=vendor --chown=www-data:www-data /app /var/www/html
COPY --from=assets --chown=www-data:www-data /app/public/build /var/www/html/public/build
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN rm -f .env database/database.sqlite \
 && chown -R www-data:www-data storage bootstrap/cache database

USER www-data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["entrypoint.sh"]
CMD ["apache2-foreground"]
