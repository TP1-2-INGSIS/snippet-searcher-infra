#!/bin/sh
# Arranque del proxy en Swarm: renderiza la config y la recarga cada 6 h
# para tomar los certificados renovados por el servicio certbot.
set -e
sh /nginx-src/render-conf.sh
(
  while :; do
    sleep 6h
    sh /nginx-src/render-conf.sh && nginx -s reload
  done
) &
exec nginx -g 'daemon off;'
