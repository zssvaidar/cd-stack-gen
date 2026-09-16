FROM nginx:1.27-alpine

COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

# nginx serves the built PHP app's static assets and needs try_files to see
# the same public/ directory php-fpm serves from - the compose file mounts/
# copies it in; here we COPY it so the nginx image is self-contained and
# deployable on its own (e.g. to EC2 without the php image also being local).
COPY app/public /var/www/html/public

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O- http://127.0.0.1:80/healthz >/dev/null 2>&1 || exit 1
