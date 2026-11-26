#!/bin/sh
# Genera /etc/nginx/conf.d/default.conf segun el estado de los certificados.
#  - Si existe el certificado de $DOMAIN: plantilla HTTPS (ssl.conf.template).
#  - Si no: configuracion HTTP (default.conf), necesaria para el desafio ACME inicial.
# Requiere DOMAIN en el entorno.
set -e
SRC=/nginx-src/conf.d
OUT=/etc/nginx/conf.d/default.conf

if [ -n "$DOMAIN" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  envsubst '${DOMAIN}' < "$SRC/ssl.conf.template" > "$OUT"
  echo "render-conf: HTTPS activo para $DOMAIN"
else
  cp "$SRC/default.conf" "$OUT"
  echo "render-conf: sin certificado para '$DOMAIN', usando HTTP"
fi
