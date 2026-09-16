# PHP-FPM runtime for project-9. Multi-stage so Composer, dev dependencies,
# and build tools never reach the final image layer - only vendor/ (no-dev)
# and the app source do.
#
# ARG PHP_VERSION makes "configure PHP8" a build-time choice instead of
# something hand-edited later: `docker build --build-arg PHP_VERSION=8.2 ...`
# targets a different 8.x without touching this file.
ARG PHP_VERSION=8.3

FROM composer:2 AS composer_bin

FROM php:${PHP_VERSION}-fpm-alpine AS build
COPY --from=composer_bin /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Composer needs a couple of PHP extensions present even to just resolve/
# install packages that require them (opcache doesn't, but a real Laravel
# app's composer.json commonly requires ext-pdo, ext-mbstring, etc. - add
# more docker-php-ext-install lines here as the app's composer.json grows).
RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS icu-dev libzip-dev \
    && docker-php-ext-install -j"$(nproc)" opcache pdo pdo_mysql intl zip

# Dependency layer cached separately from app source: this RUN only
# re-executes when composer.json/composer.lock change, not on every source edit.
COPY app/composer.json app/composer.lock* ./
RUN composer install \
        --no-dev \
        --no-scripts \
        --no-autoloader \
        --no-interaction \
        --prefer-dist

COPY app/ .
RUN composer dump-autoload --optimize --no-dev --classmap-authoritative \
    && composer validate --strict --no-check-publish

FROM php:${PHP_VERSION}-fpm-alpine AS runtime
ARG PHP_VERSION
LABEL org.opencontainers.image.description="project-9 mock app - php-fpm ${PHP_VERSION}"

# Same extensions as the build stage, minus the *-dev headers (.build-deps),
# which this stage never installs, so the runtime image doesn't carry a
# compiler toolchain it has no further use for.
RUN apk add --no-cache icu-libs libzip \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS icu-dev libzip-dev \
    && docker-php-ext-install -j"$(nproc)" opcache pdo pdo_mysql intl zip \
    && apk del .build-deps

# vault + jq are here so docker-entrypoint.sh can fetch secrets itself with
# no other moving parts - the tradeoff (Vault CLI and, briefly, an AppRole
# secret_id present inside the app image's runtime) is spelled out in
# ../../docs/vault-secret-injection.md alongside the sidecar alternative that
# avoids it. Pin the version like project-8's Jenkins agent image does.
ARG VAULT_VERSION=1.18.1
RUN apk add --no-cache --virtual .vault-deps curl unzip \
    && curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_$(case "$(uname -m)" in x86_64) echo amd64;; aarch64) echo arm64;; esac).zip" \
        -o /tmp/vault.zip \
    && unzip -q /tmp/vault.zip -d /usr/local/bin \
    && rm /tmp/vault.zip \
    && apk del .vault-deps \
    && apk add --no-cache jq

COPY docker/php/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/php/docker-entrypoint.sh /usr/local/bin/app-entrypoint.sh
RUN chmod +x /usr/local/bin/app-entrypoint.sh

# The php-fpm base image already creates and runs as an unprivileged "www-data"
# equivalent on some variants but not consistently across php:*-fpm-alpine
# tags, so pin our own "app" user/group explicitly rather than relying on it.
RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

# docker-entrypoint.sh runs as the unprivileged "app" user (USER below) and
# needs to mv one of these two files into place at container start to pick
# prod vs dev opcache behavior. A plain chown of the *files* is not enough -
# mv/rename needs write on the *directory* they live in, and conf.d/ stays
# root-owned on purpose (nothing else should be able to write there). So
# these two live in their own app-owned directory instead, added to PHP's
# ini scan path alongside (not instead of - PHP_INI_SCAN_DIR overrides the
# compiled-in default entirely once set) the real conf.d/.
ENV PHP_INI_SCAN_DIR="/usr/local/etc/php/conf.d:/usr/local/etc/php/app-conf.d"
RUN mkdir -p /usr/local/etc/php/app-conf.d && chown app:app /usr/local/etc/php/app-conf.d
COPY --chown=app:app docker/php/conf.d/opcache-prod.ini /usr/local/etc/php/app-conf.d/opcache-prod.ini.disabled
COPY --chown=app:app docker/php/conf.d/opcache-dev.ini /usr/local/etc/php/app-conf.d/opcache-dev.ini.disabled

WORKDIR /var/www/html
COPY --from=build --chown=app:app /var/www/html /var/www/html

# storage/ and bootstrap/cache/ are the only paths a Laravel app writes to
# at runtime (logs, compiled views, framework cache) - everything else stays
# read-only. This mock app has no such directories, so this is a no-op here
# but is what a real Laravel swap-in needs uncommented.
# RUN mkdir -p storage bootstrap/cache && chown -R app:app storage bootstrap/cache

USER app
EXPOSE 9000

# Confirms the fpm master process is actually alive, not just that the
# container hasn't exited - pgrep needs procps, already pulled in by the
# alpine base's busybox (pgrep is a busybox applet here, no extra package).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD pgrep -f 'php-fpm: master process' || exit 1

ENTRYPOINT ["/usr/local/bin/app-entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]
