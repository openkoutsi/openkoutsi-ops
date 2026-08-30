#!/usr/bin/env bash
#
# Build Valhalla routing tiles for one region on THIS machine and ship the
# minimal serving payload to the ops VM (issue #56 — self-hosted, off-by-default
# OSM surface classification). Run this locally, never on the VM: building is
# CPU/RAM-heavy (a full-country build was observed to exceed 1 GB of RAM and
# climbing), and the production box is a 2-core/2GB Starter plan already
# running everything else. The VM only ever serves pre-built tiles; tile_urls
# is left empty in its own environment.
#
# This is the one deliberate exception to "CI builds, the VM pulls, the VM
# never builds": re-run this by hand whenever a region's OSM data needs
# refreshing.
#
# What it does:
#   1. Builds tiles for --region via a throwaway ghcr.io/valhalla/valhalla-scripted
#      container (downloads the Geofabrik extract itself).
#   2. Sanity-checks the result with a real bicycle /route call.
#   3. rsyncs only what serving needs: the packed tile bundle plus the small
#      support databases — not the loose tile directory (redundant with the
#      bundle), not the source PBF (build-time input only), not elevation data
#      (openkoutsi derives elevation from the GPX itself). Verified locally to
#      cut the shipped payload from ~5 GB to under 1 GB.
#
# Usage:
#   scripts/valhalla-build-and-ship.sh --region europe/finland --host 1.2.3.4
#
# Options:
#   --region PATH     Geofabrik path relative to download.geofabrik.de, e.g.
#                      europe/finland or north-america/us/california. Required.
#   --host HOST       VM address, matching `ssh deploy@HOST`. Required unless
#                      --skip-upload is given.
#   --user USER       Remote SSH user. Default: deploy.
#   --jump-host SPEC  Bastion to hop through. Only needed if you can't reach
#                      --host directly. If you have a Host block for this VM in
#                      ~/.ssh/config already (recommended if you're doing this
#                      more than once), ProxyJump there instead and skip this.
#                      By default this tunnels through the bastion via ssh -J,
#                      so THIS machine still authenticates to --host end to
#                      end — it just needs routing help, not a different key.
#   --jump-host-relay Use with --jump-host when the identity that authenticates
#                      to --host lives only on the bastion, not here. Instead
#                      of tunneling, this logs into --jump-host and runs the
#                      final ssh/rsync FROM there, so the bastion's own key (or
#                      agent) does that hop's auth. --host must be reachable
#                      from the bastion's own network position.
#   --remote-path P   Remote directory the payload lands in. Default:
#                      /opt/openkoutsi/data/valhalla
#   --work-dir DIR    Local build directory. Default: ./.valhalla-build/<region>
#   --skip-build      Reuse an existing local build in --work-dir; upload only.
#   --skip-upload     Build and verify locally; skip the rsync step.
#   --dry-run         Pass -n to rsync: show what would transfer, change nothing.
#   -h, --help        Show this help.
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed '$d; s/^#!\{0,1\} \{0,1\}//'
}

IMAGE="ghcr.io/valhalla/valhalla-scripted:latest"
LOCAL_PORT=8099

REGION=""
HOST=""
REMOTE_USER="deploy"
REMOTE_PATH="/opt/openkoutsi/data/valhalla"
JUMP_HOST=""
JUMP_RELAY=0
WORK_DIR=""
SKIP_BUILD=0
SKIP_UPLOAD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --remote-path) REMOTE_PATH="$2"; shift 2 ;;
    --jump-host) JUMP_HOST="$2"; shift 2 ;;
    --jump-host-relay) JUMP_RELAY=1; shift ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$REGION" ] || { echo "error: --region is required (e.g. europe/finland)" >&2; exit 1; }
if [ "$SKIP_UPLOAD" -eq 0 ] && [ -z "$HOST" ]; then
  echo "error: --host is required unless --skip-upload is given" >&2
  exit 1
fi
if [ "$JUMP_RELAY" -eq 1 ] && [ -z "$JUMP_HOST" ]; then
  echo "error: --jump-host-relay requires --jump-host" >&2
  exit 1
fi

REGION_SLUG=$(echo "$REGION" | tr '/' '-')
WORK_DIR="${WORK_DIR:-./.valhalla-build/${REGION_SLUG}}"
CUSTOM_FILES="${WORK_DIR}/custom_files"
CONTAINER_NAME="valhalla-build-${REGION_SLUG}"
PBF_URL="https://download.geofabrik.de/${REGION}-latest.osm.pbf"

cleanup() { docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> Building tiles for ${REGION} (${PBF_URL})"
  mkdir -p "$CUSTOM_FILES"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -dt --name "$CONTAINER_NAME" -p "${LOCAL_PORT}:8002" \
    -v "$(cd "$CUSTOM_FILES" && pwd):/custom_files" \
    -e tile_urls="$PBF_URL" \
    -e build_elevation=False \
    -e use_tiles_ignore_pbf=True \
    -e serve_tiles=True \
    "$IMAGE" >/dev/null

  echo "==> Waiting for the build + server start (the slow, CPU-heavy part)..."
  ELAPSED=0
  until curl -s -m 2 "http://localhost:${LOCAL_PORT}/status" >/dev/null 2>&1; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      echo "error: container exited before serving — last logs:" >&2
      docker logs "$CONTAINER_NAME" 2>&1 | tail -50 >&2
      exit 1
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    printf "\r   ...%dm%02ds" $((ELAPSED / 60)) $((ELAPSED % 60))
  done
  echo
  echo "==> Serving after ${ELAPSED}s. Sanity-checking with a real route..."
  ROUTE=$(curl -s -m 10 -X POST "http://localhost:${LOCAL_PORT}/route" \
    -d '{"locations":[{"lat":60.17,"lon":24.94},{"lat":60.18,"lon":24.96}],"costing":"bicycle"}')
  if ! echo "$ROUTE" | grep -q '"trip"'; then
    echo "error: /route returned no trip — ${REGION} may be the wrong path, or" >&2
    echo "the two hardcoded sanity-check coordinates (Helsinki) fall outside it." >&2
    echo "Response: $ROUTE" >&2
    exit 1
  fi
  echo "==> Route check passed."
else
  echo "==> --skip-build: reusing existing build in ${CUSTOM_FILES}"
  [ -f "${CUSTOM_FILES}/valhalla_tiles.tar" ] || {
    echo "error: no valhalla_tiles.tar in ${CUSTOM_FILES}" >&2
    exit 1
  }
fi

# Only what serving needs — see the header comment for what's excluded and why.
PAYLOAD=(valhalla_tiles.tar admins.sqlite timezones.sqlite default_speeds.json valhalla.json)

echo "==> Payload:"
(cd "$CUSTOM_FILES" && du -ch "${PAYLOAD[@]}" 2>/dev/null | tail -1)

if [ "$SKIP_UPLOAD" -eq 1 ]; then
  echo "==> --skip-upload: stopping after local build. Files are in ${CUSTOM_FILES}"
  exit 0
fi

RSYNC_FLAGS=(-avz --progress)
[ "$DRY_RUN" -eq 1 ] && RSYNC_FLAGS+=(-n)

if [ "$JUMP_RELAY" -eq 1 ]; then
  # The key for $HOST lives only on $JUMP_HOST, never on this machine — a
  # ProxyJump tunnel can't use it, because that leaves THIS machine's ssh doing
  # the full handshake with $HOST, which needs an identity it doesn't have.
  # Instead of tunneling, log into $JUMP_HOST and run the final ssh/rsync FROM
  # there, so $JUMP_HOST's own identity authenticates that hop. This assumes
  # neither $REMOTE_PATH nor $HOST contains spaces — ssh re-joins a multi-hop
  # command with plain spaces at each hop, which does not survive quoting
  # through more than one relay.
  MKDIR_CMD=(ssh "$JUMP_HOST" ssh "${REMOTE_USER}@${HOST}" mkdir -p "${REMOTE_PATH}")
  RSYNC_FLAGS+=(-e "ssh ${JUMP_HOST} ssh")
  VIA_DESC=" via ${JUMP_HOST} (relayed — ${JUMP_HOST}'s own identity authenticates to ${HOST})"
elif [ -n "$JUMP_HOST" ]; then
  MKDIR_CMD=(ssh -J "$JUMP_HOST" "${REMOTE_USER}@${HOST}" "mkdir -p '${REMOTE_PATH}'")
  RSYNC_FLAGS+=(-e "ssh -J ${JUMP_HOST}")
  VIA_DESC=" via ${JUMP_HOST}"
else
  MKDIR_CMD=(ssh "${REMOTE_USER}@${HOST}" "mkdir -p '${REMOTE_PATH}'")
  VIA_DESC=""
fi

echo "==> Shipping to ${REMOTE_USER}@${HOST}:${REMOTE_PATH}/${VIA_DESC}"
"${MKDIR_CMD[@]}"
(cd "$CUSTOM_FILES" && rsync "${RSYNC_FLAGS[@]}" "${PAYLOAD[@]}" "${REMOTE_USER}@${HOST}:${REMOTE_PATH}/")

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> Dry run only — nothing changed on ${HOST}."
else
  echo "==> Done. Tiles are on ${HOST}, but the service isn't live until the"
  echo "    \"valhalla\" Compose profile is enabled (COMPOSE_PROFILES in"
  echo "    stack.env) and the next deploy poll runs."
fi
