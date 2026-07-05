#!/usr/bin/env bash
#
# Cap the size of nginx's access.log. nginx has no built-in size-based rotation,
# so this runs on the oknginx-logrotate.timer (hourly): when access.log grows
# past NGINX_ACCESS_LOG_MAX_MB it is rotated out, nginx is told to reopen its log
# files (so it starts a fresh access.log), and the rotated file is compressed.
# NGINX_ACCESS_LOG_KEEP compressed generations are retained; older ones go.
# Safe to run by hand.
#
# The log lives in the nginx_logs volume on the VM's OS disk
# (${LOG_MOUNT}/nginx_logs), so an unbounded access.log would eat the OS disk.
# GoAccess reads the live access.log, so after a rotation its report reflects
# only the current (post-rotation) window — an accepted trade-off for a hard size
# cap on the small single VM.

set -euo pipefail

cd /opt/openkoutsi

# Non-secret config for compose interpolation + this script (LOG_MOUNT,
# NGINX_ACCESS_LOG_*). Sourced the same way as okdeploy-pull.sh / oklog-prune.sh.
set -a
# shellcheck disable=SC1091
. /opt/openkoutsi/stack.env
set +a

ACCESS_LOG="${LOG_MOUNT}/nginx_logs/access.log"
MAX_MB="${NGINX_ACCESS_LOG_MAX_MB:-100}"
KEEP="${NGINX_ACCESS_LOG_KEEP:-5}"
MAX_BYTES=$(( MAX_MB * 1024 * 1024 ))

# Nothing to do until nginx has created a REAL (non-symlink) access.log that is
# over the cap. The [ -L ] check guards the stock image's stdout symlink before
# nginx has stripped it (see the nginx service in docker-compose.yml).
if [ ! -f "${ACCESS_LOG}" ] || [ -L "${ACCESS_LOG}" ]; then
    exit 0
fi
if [ "$(stat -c %s "${ACCESS_LOG}")" -le "${MAX_BYTES}" ]; then
    exit 0
fi

# Shift existing compressed generations up, oldest first so nothing is clobbered:
# drop .KEEP.gz, then .(KEEP-1).gz -> .KEEP.gz, ..., .1.gz -> .2.gz.
rm -f "${ACCESS_LOG}.${KEEP}.gz"
i=$(( KEEP - 1 ))
while [ "${i}" -ge 1 ]; do
    [ -f "${ACCESS_LOG}.${i}.gz" ] && mv "${ACCESS_LOG}.${i}.gz" "${ACCESS_LOG}.$(( i + 1 )).gz"
    i=$(( i - 1 ))
done

# Move the live log aside and have nginx reopen — it recreates access.log and
# resumes writing there. Compress only AFTER the reopen so in-flight lines that
# nginx still holds on the old descriptor are flushed to the rotated file first.
mv "${ACCESS_LOG}" "${ACCESS_LOG}.1"

nginx_cid="$(docker compose -f /opt/openkoutsi/docker-compose.yml ps -q nginx 2>/dev/null || true)"
if [ -n "${nginx_cid}" ]; then
    docker exec "${nginx_cid}" nginx -s reopen
    sleep 2
fi

gzip -f "${ACCESS_LOG}.1"
