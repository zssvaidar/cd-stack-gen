#!/usr/bin/env bash
# Sourced by build.sh/test.sh/deploy.sh. Every function here answers "has
# this already happened?" so the calling script can skip work instead of
# blindly redoing it - reinstalling an already-installed package, restarting
# an already-running healthy service, or rebuilding an image that already
# exists for this exact source tree all cause needless downtime/drift.

# command_exists <name>
command_exists() { command -v "$1" >/dev/null 2>&1; }

# apt_package_installed <name>  (Debian/Ubuntu hosts, e.g. the EC2 target)
apt_package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

# systemd_service_active <unit>
systemd_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# systemd_service_exists <unit>  - unit file present, whether or not it's running
systemd_service_exists() {
    systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q "^$1"
}

# docker_image_exists <tag>
docker_image_exists() {
    [ -n "$(docker images -q "$1" 2>/dev/null)" ]
}

# docker_container_running <name>
docker_container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true"  ]
}

# docker_container_exists <name>  - exists in any state (running, stopped, created)
docker_container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

# port_listening <port>
port_listening() {
    # Prefer ss (iproute2, present on modern hosts and most CI images);
    # fall back to netstat for older targets.
    if command_exists ss; then
        ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q ":$1"
    elif command_exists netstat; then
        netstat -ltn 2>/dev/null | grep -q ":$1 "
    else
        return 1
    fi
}

# nginx_config_valid <container-or-empty>  - empty = check the host's nginx
nginx_config_valid() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        docker exec "$target" nginx -t >/dev/null 2>&1
    else
        nginx -t >/dev/null 2>&1
    fi
}

# apache_config_valid <container-or-empty>
apache_config_valid() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        docker exec "$target" httpd -t >/dev/null 2>&1
    else
        apachectl -t >/dev/null 2>&1
    fi
}

# php_syntax_valid <file>
php_syntax_valid() {
    php -l "$1" >/dev/null 2>&1
}

# image_content_hash <path>  - stable hash of a directory's tracked-by-git
# content, used to decide whether a rebuild would actually change anything
# (see build.sh). Falls back to a full recursive checksum outside a git repo.
image_content_hash() {
    local path="$1"
    if git -C "$path" rev-parse >/dev/null 2>&1; then
        git -C "$path" ls-files -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    else
        find "$path" -type f -exec sha256sum {} \; | sort | sha256sum | cut -d' ' -f1
    fi
}
