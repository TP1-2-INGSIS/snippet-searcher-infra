#!/bin/bash
set -e

if [ -f .env ]; then
  export $(grep -v '^#' .env | awk '/=/ {print $1}')
fi

if [ -z "$DOMAIN" ] || [ -z "$CERTBOT_EMAIL" ]; then
  echo "Error: Debes definir DOMAIN y CERTBOT_EMAIL en tu archivo .env"
  exit 1
fi

echo "=== 1. Asegurando que el stack esté desplegado en HTTP para el desafío ACME ==="
docker stack deploy --resolve-image=never -c docker-stack.yml snippet-searcher

echo "=== 2. Solicitando certificado real a Let's Encrypt para $DOMAIN ==="
sleep 5

docker run --rm \
  -v snippet-searcher_certbot_conf:/etc/letsencrypt \
  -v snippet-searcher_certbot_www:/var/www/certbot \
  certbot/certbot certonly \
  --webroot \
  -w /var/www/certbot \
  -d "$DOMAIN" \
  --email "$CERTBOT_EMAIL" \
  --rsa-key-size 4096 \
  --agree-tos \
  --non-interactive

echo "=== 3. Activando configuración HTTPS (TLS) en NGINX ==="
# El proxy renderiza su config según exista o no el certificado (nginx/render-conf.sh).
PROXY_CONTAINER=$(docker ps -q -f name=snippet-searcher_proxy | head -n 1)
if [ -n "$PROXY_CONTAINER" ]; then
  docker exec "$PROXY_CONTAINER" sh /nginx-src/render-conf.sh
  docker exec "$PROXY_CONTAINER" nginx -s reload
  echo "Certificado emitido y NGINX recargado con éxito en https://$DOMAIN"
else
  echo "Error: No se encontró el contenedor snippet-searcher_proxy corriendo."
  exit 1
fi
