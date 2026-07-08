#!/usr/bin/env bash
#
# Poll GHCR for new images and recreate only the services whose image changed.
# Invoked by okdeploy.service on the okdeploy.timer schedule. Safe to run by hand.
#
# `docker compose up -d` is a no-op for services whose image digest is unchanged,
# so a poll where nothing moved costs only a registry HEAD per image.

set -euo pipefail

cd /opt/openkoutsi

# Non-secret config for compose variable interpolation (DATA_MOUNT, *_URL, ...).
set -a
# shellcheck disable=SC1091
. /opt/openkoutsi/stack.env
set +a

docker compose pull --quiet

# nginx proxies to the app containers by service name (proxy_pass http://backend:8000
# etc.) with no `resolver`, so it resolves each upstream to an IP once at config-load
# time and caches it for the worker's lifetime. When `up -d` recreates a service whose
# image changed, that container comes back on a NEW Docker-network IP, but the nginx
# container is left untouched — it keeps routing to the dead IP until its next 6h
# cert-reload, causing 502/504s in the meantime. So reload nginx whenever `up -d`
# actually recreated something. Compare the running container-ID set before/after: any
# recreation (image or config change) mints new IDs, an unchanged poll leaves them be.
before=$(docker compose ps -q | sort)
docker compose up -d --remove-orphans
after=$(docker compose ps -q | sort)

if [ "$before" != "$after" ]; then
    # A just-recreated nginx already has fresh upstream IPs, so the reload is at worst
    # a harmless no-op; -T avoids TTY allocation under systemd.
    docker compose exec -T nginx nginx -s reload
fi

docker image prune -f
