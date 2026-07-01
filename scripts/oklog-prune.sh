#!/usr/bin/env bash
#
# Prune old per-service log files written by the vector collector.
# Invoked by oklog-prune.service on the oklog-prune.timer schedule (daily).
# Safe to run by hand.
#
# Vector writes daily files at ${LOG_MOUNT}/service_logs/<container>/<date>.log
# (on the VM's OS disk, not the data device). Anything older than
# LOG_RETENTION_DAYS is deleted; empty dirs are tidied up.

set -euo pipefail

# Non-secret config (LOG_MOUNT, LOG_RETENTION_DAYS).
set -a
# shellcheck disable=SC1091
. /opt/openkoutsi/stack.env
set +a

LOG_DIR="${LOG_MOUNT}/service_logs"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

[ -d "${LOG_DIR}" ] || exit 0

find "${LOG_DIR}" -type f -name '*.log' -mtime "+${RETENTION_DAYS}" -delete
# Remove now-empty per-service directories (but keep vector's .vector state dir).
find "${LOG_DIR}" -mindepth 1 -type d -not -name '.vector' -empty -delete
