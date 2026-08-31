#!/usr/bin/env bash
# Vérifie la chaîne complète : DDNS -> certificat -> wildcard -> proxy.
# Usage : ./scripts/verify.sh [port_https]   (défaut 8443, le port de test)
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "!! .env absent"; exit 1; }
set -a; . ./.env; set +a
PORT="${1:-8443}"
ok=0; ko=0
chk() { if [ "$1" = 0 ]; then echo "  [OK]   $2"; ok=$((ok+1)); else echo "  [ECHEC] $2"; ko=$((ko+1)); fi; }

echo "== 1. Conteneur =="
docker compose ps --status running --format '{{.Service}}' | grep -q caddy
chk $? "le conteneur caddy tourne"

echo "== 2. DNS dynamique =="
ip_pub=$(curl -s --max-time 5 https://icanhazip.com)
ip_dns=$(dig +short @1.1.1.1 "$DOMAIN" A | tail -1)
echo "     IP publique : $ip_pub"
echo "     IP dans DNS : $ip_dns"
[ -n "$ip_pub" ] && [ "$ip_pub" = "$ip_dns" ]
chk $? "le record DNS pointe sur l'IP publique actuelle"

echo "== 3. Certificat =="
sans=$(openssl s_client -connect "127.0.0.1:$PORT" -servername "home.$DOMAIN" </dev/null 2>/dev/null \
       | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')
issuer=$(openssl s_client -connect "127.0.0.1:$PORT" -servername "home.$DOMAIN" </dev/null 2>/dev/null \
       | openssl x509 -noout -issuer 2>/dev/null)
echo "     SANs   : ${sans:-<aucun>}"
echo "     Issuer : ${issuer:-<aucun>}"
echo "$sans" | grep -q "DNS:\*\.$DOMAIN"
chk $? "le certificat couvre le wildcard *.$DOMAIN"

echo "== 4. Proxy =="
# -k : en staging le certificat n'est pas de confiance, c'est normal.
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "home.$DOMAIN:$PORT:127.0.0.1" "https://home.$DOMAIN:$PORT/")
[ "$code" = 200 ]; chk $? "home.$DOMAIN répond ($code) <- prouve le wildcard"
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "inexistant.$DOMAIN:$PORT:127.0.0.1" "https://inexistant.$DOMAIN:$PORT/")
[ "$code" = 000 ]; chk $? "sous-domaine non déclaré refusé (abort)"

echo
echo "== $ok OK, $ko en échec =="
[ "$ko" = 0 ]
