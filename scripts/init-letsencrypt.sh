#!/bin/bash
# ==============================================================================
# Script para inicializar certificados TLS de Let's Encrypt con DuckDNS en la VM
# ==============================================================================

if [ -f .env ]; then
  export $(cat .env | grep -v '#' | awk '/=/ {print $1}')
fi

if [ -z "$DOMAIN" ] || [ -z "$CERTBOT_EMAIL" ]; then
  echo "Error: Debes definir DOMAIN y CERTBOT_EMAIL en tu archivo .env"
  exit 1
fi

echo "=== 1. Creando certificados temporales para levantar Nginx ==="
mkdir -p ./certbot/conf/live/$DOMAIN
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout ./certbot/conf/live/$DOMAIN/privkey.pem \
  -out ./certbot/conf/live/$DOMAIN/fullchain.pem \
  -subj "/CN=localhost"

echo "=== 2. Levantando Nginx en el stack de Swarm ==="
docker stack deploy -c docker-stack.yml snippet-searcher

echo "=== 3. Solicitando certificado real a Let's Encrypt ==="
# Esperar que Nginx esté listo
sleep 10

docker run --rm \
  -v snippet-searcher_certbot_conf:/etc/letsencrypt \
  -v snippet-searcher_certbot_www:/var/www/certbot \
  certbot/certbot certonly \
  --webroot \
  -w /var/www/certbot \
  -d $DOMAIN \
  --email $CERTBOT_EMAIL \
  --rsa-key-size 4096 \
  --agree-tos \
  --non-interactive \
  --force-renewal

echo "=== 4. Recargando Nginx ==="
PROXY_CONTAINER=$(docker ps -q -f name=snippet-searcher_proxy)
if [ -n "$PROXY_CONTAINER" ]; then
  docker exec $PROXY_CONTAINER nginx -s reload
  echo "Certificado emitido y Nginx recargado con éxito para $DOMAIN."
else
  echo "Stack desplegado. Verifica con: docker stack services snippet-searcher"
fi
