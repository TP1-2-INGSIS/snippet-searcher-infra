#!/bin/bash
set -e

# Mismo cargador que deploy.yml: el .env se evalúa como shell, por eso los valores
# deben ir entre comillas simples (ver README).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "$DOMAIN" ] || [ -z "$CERTBOT_EMAIL" ]; then
  echo "Error: Debes definir DOMAIN y CERTBOT_EMAIL en tu archivo .env"
  exit 1
fi

echo "=== 1. Asegurando que el stack esté desplegado en HTTP para el desafío ACME ==="
docker stack deploy --resolve-image=never -c docker-stack.yml snippet-searcher

echo "=== 2. Solicitando certificado real a Let's Encrypt para $DOMAIN ==="
echo "Esperando a que el proxy responda en el puerto 80 (máx. 120 s)..."
ready=false
for _ in $(seq 1 40); do
  if [ -n "$(docker ps -q -f name=snippet-searcher_proxy -f status=running)" ] \
     && curl -s -o /dev/null --max-time 3 http://127.0.0.1/; then
    ready=true
    break
  fi
  sleep 3
done
if [ "$ready" != true ]; then
  echo "Error: el proxy no respondió en el puerto 80 a tiempo."
  exit 1
fi

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
