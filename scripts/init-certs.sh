#!/usr/bin/env bash
#
# First-boot TLS bootstrap for the openkoutsi stack.
#
# nginx's server blocks reference /etc/letsencrypt/live/openkoutsi/fullchain.pem,
# but on a fresh VM that cert does not exist yet — so nginx can't start, and while
# nginx is down it can't serve certbot's HTTP-01 webroot challenge to *get* a cert.
# This breaks the deadlock: lay down a throwaway self-signed cert so nginx boots,
# bring nginx up, obtain the real Let's Encrypt cert over the webroot challenge,
# then reload nginx onto the real cert.
#
# Idempotent: if a real (non-bootstrap) cert is already present it does nothing,
# so it is safe to run on every boot and to re-run by hand. Run with FORCE_CERT=1
# to re-request even when a cert exists.

set -euo pipefail

cd /opt/openkoutsi

# Non-secret config (DATA_MOUNT, CERT_DOMAINS, CERT_EMAIL, CERT_NAME, CERT_STAGING).
set -a
# shellcheck disable=SC1091
. /opt/openkoutsi/stack.env
set +a

CERT_NAME="${CERT_NAME:-openkoutsi}"
LIVE_HOST="${DATA_MOUNT}/letsencrypt/live/${CERT_NAME}"

# Already have a real cert? (bootstrap certs carry O=openkoutsi-bootstrap.)
if [ -f "${LIVE_HOST}/fullchain.pem" ] && [ "${FORCE_CERT:-0}" != "1" ]; then
  if ! openssl x509 -in "${LIVE_HOST}/fullchain.pem" -noout -subject 2>/dev/null \
        | grep -q "openkoutsi-bootstrap"; then
    echo "init-certs: real certificate already present for ${CERT_NAME}; nothing to do."
    exit 0
  fi
fi

# 1. Throwaway self-signed cert so nginx has something to load.
echo "init-certs: writing temporary self-signed cert so nginx can start..."
mkdir -p "${LIVE_HOST}"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout "${LIVE_HOST}/privkey.pem" \
  -out "${LIVE_HOST}/fullchain.pem" \
  -subj "/CN=${CERT_NAME}/O=openkoutsi-bootstrap" >/dev/null 2>&1

# 2. Bring nginx (and its deps) up so it can serve the ACME challenge on :80.
echo "init-certs: starting nginx..."
docker compose up -d nginx
sleep 3

# 3. Request the real certificate (one SAN cert covering every hostname).
domain_args=()
for d in ${CERT_DOMAINS}; do
  domain_args+=(-d "${d}")
done

staging_arg=""
if [ "${CERT_STAGING:-0}" = "1" ]; then
  echo "init-certs: using Let's Encrypt STAGING (untrusted certs, no rate limits)."
  staging_arg="--staging"
fi

# Remove the throwaway lineage so certbot creates a clean one under the same name.
rm -rf "${DATA_MOUNT}/letsencrypt/live/${CERT_NAME}" \
       "${DATA_MOUNT}/letsencrypt/archive/${CERT_NAME}" \
       "${DATA_MOUNT}/letsencrypt/renewal/${CERT_NAME}.conf"

echo "init-certs: requesting certificate for: ${domain_args[*]}"
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  --cert-name "${CERT_NAME}" "${domain_args[@]}" \
  --email "${CERT_EMAIL}" --agree-tos --no-eff-email \
  --non-interactive ${staging_arg}

# 4. Reload nginx onto the real cert.
echo "init-certs: reloading nginx onto the real certificate."
docker compose exec nginx nginx -s reload 2>/dev/null \
  || docker compose restart nginx

echo "init-certs: done."
