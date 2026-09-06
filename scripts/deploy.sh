#!/usr/bin/env bash
# Deploy the hermes nginx cache-node config from this repo.
#   bash scripts/deploy.sh [hermes-host]
# Default host: oracle-hermes (see ~/.ssh/config). The private key
# (/etc/nginx/ssl/hermes-key.pem) is NOT in this repo and must already be
# present on the box — this script never touches it.
set -euo pipefail

HOST="${1:-oracle-hermes}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== copying configs to $HOST ==="
scp "$REPO_DIR/nginx.conf" "$HOST:/tmp/nginx.conf"
scp "$REPO_DIR/conf.d/radar-cache.conf" "$HOST:/tmp/radar-cache.conf"
scp "$REPO_DIR/ssl/hermes-cert.pem" "$HOST:/tmp/hermes-cert.pem"

echo "=== installing + testing ==="
ssh "$HOST" "sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf && \
             sudo cp /tmp/radar-cache.conf /etc/nginx/conf.d/radar-cache.conf && \
             sudo cp /tmp/hermes-cert.pem /etc/nginx/ssl/hermes-cert.pem && \
             sudo nginx -t"

echo "=== reloading nginx ==="
ssh "$HOST" "sudo nginx -s reload"

echo "=== verifying :8443 ==="
ssh "$HOST" "ss -tln | grep 8443 && curl -sk -o /dev/null -w 'health: %{http_code} %{time_total}s\n' https://localhost:8443/api/v1/health"
echo "done"
