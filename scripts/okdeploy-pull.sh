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
docker compose up -d --remove-orphans
docker image prune -f
