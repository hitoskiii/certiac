#!/usr/bin/env bash
# Vérifie la configuration AVANT de démarrer, pour éviter une boucle de
# redémarrage dont le message d'erreur est peu explicite.
# Usage : ./scripts/preflight.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ko=0
err() { echo "  [ECHEC] $1"; ko=$((ko+1)); }
ok()  { echo "  [OK]    $1"; }

echo "== Fichier .env =="
if [ ! -f .env ]; then
  err ".env absent — il n'est pas versionné. Faire : cp .env.example .env"
  echo; echo "== 1 problème bloquant =="; exit 1
fi
ok ".env présent"
set -a; . ./.env; set +a

echo "== Variables communes =="
for v in DNS_PROVIDER DOMAIN SITE_ADDRESSES HTTPS_PORT ACME_EMAIL; do
  if [ -z "${!v:-}" ]; then err "$v vide"; else ok "$v = ${!v}"; fi
done

echo "== Fragments du provider =="
for f in "providers/$DNS_PROVIDER.tls.caddyfile" "providers/$DNS_PROVIDER.ddns.caddyfile"; do
  if [ -f "$f" ]; then ok "$f"; else
    err "$f introuvable — DNS_PROVIDER='$DNS_PROVIDER' est-il correct ?"
    echo "          providers disponibles : $(ls providers/*.tls.caddyfile 2>/dev/null | xargs -n1 basename | sed 's/\.tls\.caddyfile//' | tr '\n' ' ')"
  fi
done

echo "== Secret du provider =="
case "$DNS_PROVIDER" in
  duckdns)    req="DUCKDNS_API_TOKEN" ;;
  cloudflare) req="CLOUDFLARE_API_TOKEN" ;;
  gandi)      req="GANDI_API_TOKEN" ;;
  ovh)        req="OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY" ;;
  *)          req="" ; echo "  [INFO]  provider non reconnu, secret non vérifié" ;;
esac
for v in $req; do
  if [ -z "${!v:-}" ]; then
    err "$v vide — c'est la cause de « missing API token » au démarrage"
  else
    ok "$v renseigné ($(printf '%s' "${!v}" | wc -c | tr -d ' ') caractères)"
  fi
done

echo "== Cohérence du domaine =="
case "$SITE_ADDRESSES" in
  *"$DOMAIN"*) ok "SITE_ADDRESSES contient DOMAIN" ;;
  *) err "SITE_ADDRESSES ('$SITE_ADDRESSES') ne mentionne pas DOMAIN ('$DOMAIN')" ;;
esac
if [ "$DNS_PROVIDER" = duckdns ] && [ "${SITE_ADDRESSES#*,}" != "$SITE_ADDRESSES" ]; then
  err "DuckDNS : SITE_ADDRESSES doit contenir le wildcard SEUL (voir README §5.1)"
fi

echo
if [ "$ko" = 0 ]; then echo "== Tout est en ordre — docker compose up -d =="; else echo "== $ko problème(s) à corriger avant de démarrer =="; fi
[ "$ko" = 0 ]
