FROM httpd:2.4-alpine

RUN sed -i \
    -e 's/^#LoadModule rewrite_module/LoadModule rewrite_module/' \
    -e 's/^#LoadModule proxy_module/LoadModule proxy_module/' \
    -e 's/^#LoadModule proxy_fcgi_module/LoadModule proxy_fcgi_module/' \
    conf/httpd.conf \
    && echo 'Include conf/extra/laravel.conf' >> conf/httpd.conf

COPY docker/apache/laravel.conf /usr/local/apache2/conf/extra/laravel.conf
COPY app/public /var/www/html/public

# Apache's own liveness check hits a plain static file (see laravel.conf's
# /healthz Location, which deliberately bypasses the fcgi proxy) so it
# reflects "the web server is up", independent of whether php-fpm is
# reachable - same split as the nginx image's /healthz.
RUN echo "ok" > /var/www/html/public/healthz.txt

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O- http://127.0.0.1:80/healthz >/dev/null 2>&1 || exit 1
