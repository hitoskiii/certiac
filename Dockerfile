# Caddy ne ship pas les modules tiers dans l'image officielle :
# on rebuild le binaire avec xcaddy, puis on le glisse dans l'image runtime.
#
# On embarque PLUSIEURS providers DNS d'un coup : ça ne coûte que quelques Mo
# et ça évite un rebuild le jour où on change d'hébergeur DNS.
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-dynamicdns \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/caddy-dns/ovh \
    --with github.com/caddy-dns/gandi \
    --with github.com/caddy-dns/duckdns

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
