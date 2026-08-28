# certiac

Reverse proxy auto-géré : certificat TLS généré et renouvelé tout seul, DNS
dynamique pour suivre une IP résidentielle qui change, et routage vers tes
services. Un seul conteneur Caddy, aucun cron, aucun certbot.

| Besoin | Mécanisme | Intervention |
|---|---|---|
| Génération du certificat | ACME DNS-01 au démarrage | aucune |
| Rotation | renouvellement à ~2/3 de vie, à chaud | aucune |
| Reverse proxy | `reverse_proxy` vers tes backends | 4 lignes par service |
| IP publique qui change | app `dynamic_dns`, contrôle toutes les 5 min | aucune |
| Changer d'hébergeur DNS | 2 lignes dans `.env` | pas de rebuild |

> **Avant de committer** : `.env` contient tes tokens d'API et n'est jamais
> versionné (`.gitignore`). Le volume `caddy_data` contient la clé de compte
> ACME et les certificats — il vit dans Docker, pas dans le dépôt, mais évite de
> le sauvegarder dans un dossier suivi par git. Les seuls fichiers à publier
> sont ceux listés ci-dessous.

---

## 1. Comment c'est fabriqué

```
Dockerfile                        Caddy recompilé avec les modules DNS
Caddyfile                         config principale, indépendante du provider
providers/<nom>.tls.caddyfile     provider DNS + résolveurs  (bloc tls du site)
providers/<nom>.ddns.caddyfile    bloc dynamic_dns           (global options)
docker-compose.yml                la stack de production
docker-compose.test.yml           surcouche de test (loopback + ACME staging)
scripts/verify.sh                 vérifie la chaîne de bout en bout
.env                              toute la configuration
```

L'image officielle Caddy ne contient aucun module DNS tiers. Le `Dockerfile` le
recompile avec `xcaddy` en embarquant **tous** les providers d'un coup — quelques
Mo, et surtout aucun rebuild le jour où tu changes d'hébergeur DNS.

Chaque provider a deux fragments et non un seul, parce que la config TLS et la
config DNS dynamique ne vivent pas au même niveau du Caddyfile. `DNS_PROVIDER`
dans `.env` sélectionne la paire, montée à des chemins fixes par compose.

**Pourquoi DNS-01 et pas HTTP-01** : le challenge par DNS ne demande aucun port
entrant (pratique pour tester avant d'ouvrir quoi que ce soit), il fonctionne
même si le FAI bloque le port 80, et il débloque le **certificat wildcard** —
donc ajouter un sous-domaine ne déclenche aucune émission de certificat.

---

## 2. Installer sur un nouveau serveur

### 2.1 Prérequis

- Docker et le plugin Compose (v2.24+ pour la directive `!override`)
- Un domaine, et un accès API chez son hébergeur DNS
- Une machine allumée en permanence, avec une **IP locale fixe**

Sur Debian/Ubuntu :

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # puis se déconnecter/reconnecter
docker compose version            # doit afficher 2.24 ou plus
```

### 2.2 Récupérer le projet et configurer

```bash
git clone <ton-dépôt> certiac && cd certiac
cp .env.example .env
$EDITOR .env
```

Les variables :

| Variable | Rôle |
|---|---|
| `DNS_PROVIDER` | `duckdns`, `cloudflare`, `ovh` ou `gandi` — sélectionne les fragments |
| `DOMAIN` | domaine racine, sert aux matchers `host` et au DNS dynamique |
| `SITE_ADDRESSES` | domaines réellement servis (voir l'avertissement DuckDNS §5.1) |
| `HTTPS_PORT` | port d'écoute **sur la machine hôte** (≠ port externe, voir §2.4) |
| `ACME_EMAIL` | notifications d'expiration Let's Encrypt |
| `<PROVIDER>_API_TOKEN` | le secret du provider choisi |

### 2.3 Valider sans rien exposer

Le challenge DNS-01 n'ayant besoin d'aucun port entrant, on teste toute la
chaîne avant de toucher au routeur :

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d --build
docker compose logs -f caddy
```

La surcouche de test bascule sur l'autorité ACME de **staging** (quota quasi
illimité), écoute sur `127.0.0.1` uniquement et utilise un volume séparé — donc
elle n'entre en conflit avec aucun service existant.

Attendre `certificate obtained successfully`, puis :

```bash
./scripts/verify.sh
```

Six contrôles : conteneur vivant, record DNS aligné sur l'IP publique,
certificat couvrant le wildcard, page témoin, sous-domaine wildcard, et refus
d'un sous-domaine non déclaré.

Le certificat de staging est rejeté par les navigateurs — c'est **attendu**, le
script utilise `curl -k`. Ce qu'on valide ici, c'est le token et le wildcard.

### 2.4 Passer en production

```bash
docker compose down
docker compose up -d
./scripts/verify.sh "$HTTPS_PORT"
```

Puis rediriger sur le routeur. **Deux ports différents à ne pas confondre :**

| | Valeur | Où |
|---|---|---|
| Port **externe** | **443** obligatoirement | ce que tape le navigateur |
| Port **interne** | `HTTPS_PORT` | ce qu'écoute la machine |

Ils n'ont pas besoin d'être égaux : `443 -> 192.168.1.42:8443` fonctionne très
bien avec `HTTPS_PORT=8443`. Ce qui compte, c'est que l'externe soit 443, sinon
tes URLs devront porter le port à vie.

Ouvrir en **TCP et UDP** (l'UDP, c'est HTTP/3 ; sans lui ça marche quand même,
en HTTP/2).

Le port 80 n'est ni requis ni exposé : le challenge est en DNS-01, et une
redirection HTTP→HTTPS pointerait vers le 443 standard.

### 2.5 Fixer l'IP locale — ne pas sauter cette étape

La redirection du routeur pointe vers une **adresse fixe**. Si le serveur est en
DHCP, son bail expire (souvent 24 h) et il peut récupérer une autre adresse au
prochain redémarrage : l'exposition tombe, silencieusement.

Créer une **réservation DHCP** dans le routeur, en associant l'adresse MAC du
serveur à son IP.

> **Piège macOS** : si l'adresse MAC commence par un octet dont l'avant-dernier
> bit est à 1 (`32:`, `x2:`, `x6:`, `xA:`, `xE:`), c'est une adresse *localement
> administrée* — la fonction « Adresse Wi-Fi privée ». Elle peut changer, et ta
> réservation avec. La désactiver pour ce réseau dans Réglages → Wi-Fi →
> Détails, ou passer en Ethernet.

### 2.6 Vérifier depuis l'extérieur

Le test local ne prouve rien sur le routeur. Depuis un téléphone en 4G, Wi-Fi
coupé :

```
https://whoami.<ton-domaine>
```

Depuis le réseau local, l'accès via l'IP publique peut échouer alors que tout
est correct : certains routeurs ne gèrent pas le hairpin NAT. Ce n'est pas un
symptôme de panne.

---

## 3. Changer d'hébergeur DNS

### 3.1 Vers un provider déjà livré

`duckdns`, `cloudflare`, `ovh` et `gandi` sont déjà compilés dans l'image et ont
leurs fragments. Basculer, c'est éditer `.env` :

```diff
-DNS_PROVIDER=duckdns
-DOMAIN=monserveur.duckdns.org
-SITE_ADDRESSES=*.monserveur.duckdns.org
+DNS_PROVIDER=cloudflare
+DOMAIN=mondomaine.fr
+SITE_ADDRESSES=mondomaine.fr, *.mondomaine.fr
 ...
+CLOUDFLARE_API_TOKEN=<le token>
```

```bash
docker compose up -d
./scripts/verify.sh "$HTTPS_PORT"
```

**Pas de rebuild.** Caddy émet le certificat du nouveau domaine et conserve
l'ancien dans `/data` jusqu'à expiration — rien à nettoyer.

### 3.2 Cas Cloudflare en détail

Cloudflare est le meilleur choix par défaut : API gratuite, module Caddy mature,
TXT multiples (donc l'apex fonctionne), et propagation quasi immédiate.

**a. Déléguer la zone.** Le domaine peut rester acheté n'importe où. Dans
Cloudflare : *Add a site*, choisir le plan Free, puis remplacer les serveurs de
noms chez ton registrar par les deux que Cloudflare indique. La délégation prend
de quelques minutes à quelques heures.

**b. Créer un token scopé.** Sur
`https://dash.cloudflare.com/profile/api-tokens` → *Create Custom Token* :

| Réglage | Valeur |
|---|---|
| Permissions | `Zone` / `Zone` / **Read** |
| Permissions | `Zone` / `DNS` / **Edit** |
| Zone Resources | *Include* → *Specific zone* → ton domaine |

N'utilise **pas** la Global API Key : elle donne accès à tout ton compte. Le
token ci-dessus ne peut lire et écrire que le DNS de cette zone.

**c. Remplir `.env`** comme au §3.1, avec `CLOUDFLARE_API_TOKEN`.

**d. Remettre l'apex.** Contrairement à DuckDNS, Cloudflare accepte plusieurs
TXT sur le même nom : les challenges de l'apex et du wildcard ne se piétinent
plus. Tu peux donc servir `mondomaine.fr` en plus de `*.mondomaine.fr` — d'où le
`SITE_ADDRESSES` à deux entrées.

**e. Le record wildcard.** Le fragment `cloudflare.ddns.caddyfile` déclare
`domains { {$DOMAIN} @ * }` : `dynamic_dns` crée et maintient un record `A` sur
l'apex **et** un sur `*`. C'est nécessaire chez Cloudflare, alors que DuckDNS
résout déjà `*.<nom>.duckdns.org` nativement.

> **Proxy orange** : si tu actives le proxy Cloudflare (nuage orange) sur tes
> records, c'est Cloudflare qui termine le TLS et ton certificat local ne sert
> plus à grand-chose. Pour l'architecture décrite ici, laisser les records en
> **DNS only** (nuage gris).

### 3.3 Ajouter un provider absent

Les modules disponibles sont listés sur `https://github.com/caddy-dns`.

**a. Compiler le module** — dans le `Dockerfile` :

```dockerfile
RUN xcaddy build \
    --with github.com/mholt/caddy-dynamicdns \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/caddy-dns/scaleway      # <- nouveau
```

**b. Écrire les deux fragments.** `providers/scaleway.tls.caddyfile` :

```
dns scaleway {$SCALEWAY_API_TOKEN}
resolvers 1.1.1.1 8.8.8.8
```

`providers/scaleway.ddns.caddyfile` :

```
dynamic_dns {
	provider scaleway {$SCALEWAY_API_TOKEN}
	domains {
		{$DOMAIN} @ *
	}
	ip_source simple_http https://icanhazip.com
	ip_source simple_http https://api.ipify.org
	check_interval 5m
	ttl 5m
	versions ipv4
}
```

La syntaxe d'authentification varie : certains providers prennent un token
unique en argument, d'autres un bloc (voir `ovh.tls.caddyfile` pour un exemple à
quatre valeurs). Le README du module `caddy-dns` concerné fait foi.

**c. Déclarer les variables** dans `.env.example` et `.env`.

**d. Rebuild et valider la syntaxe** sans rien démarrer :

```bash
docker compose build
docker run --rm --env-file .env \
  -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$PWD/providers/scaleway.tls.caddyfile:/etc/caddy/dns-tls.caddyfile:ro" \
  -v "$PWD/providers/scaleway.ddns.caddyfile:/etc/caddy/dns-ddns.caddyfile:ro" \
  certiac-caddy caddy adapt --config /etc/caddy/Caddyfile
```

Une sortie JSON = la config est valide. Une erreur nomme le fichier et la ligne.

---

## 4. Ajouter un service

Dans `docker-compose.yml` :

```yaml
  monapp:
    image: mon/image
    restart: unless-stopped
    networks: [proxy]      # PAS de "ports:" — Caddy est la seule porte d'entrée
```

Dans le `Caddyfile`, à l'intérieur du bloc `{$SITE_ADDRESSES}` :

```
	@monapp host monapp.{$DOMAIN}
	handle @monapp {
		reverse_proxy monapp:3000
	}
```

```bash
docker compose up -d
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Aucun certificat à émettre : le wildcard couvre déjà le sous-domaine, et le
record DNS aussi.

**Backend hors Docker** (machine du LAN, service natif) : viser l'IP et le port
directement, `reverse_proxy 192.168.1.50:8123`. Beaucoup d'applications
refusent les requêtes proxifiées tant qu'on ne leur a pas déclaré le proxy comme
étant de confiance — chercher `trusted_proxies` ou équivalent dans leur config.

---

## 5. Pièges connus

### 5.1 DuckDNS : un seul TXT par domaine

DuckDNS ne stocke **qu'un seul** enregistrement TXT par domaine. Or l'apex et le
wildcard réclament tous deux `_acme-challenge.<domaine>` : leurs valeurs
s'écrasent et l'apex n'est jamais délivré (`will retry` en boucle).

Sur DuckDNS, mettre donc **le wildcard seul** :

```
SITE_ADDRESSES=*.monserveur.duckdns.org
```

Et servir la page d'accueil sur `home.<domaine>`. Cette limite n'existe pas chez
Cloudflare, OVH ou Gandi.

### 5.2 Un wildcard ne couvre pas l'apex

`*.exemple.org` couvre `truc.exemple.org` mais **pas** `exemple.org`. Règle du
standard X.509 : l'astérisque doit correspondre à au moins un label. Un
navigateur pointé sur l'apex affichera « non sécurisé » alors que tout va bien
sur les sous-domaines.

### 5.3 Vérification de propagation

Par défaut Caddy interroge directement les serveurs autoritaires du provider
pour vérifier que son TXT est visible. Ceux de DuckDNS ne répondent pas de façon
fiable en TCP/53 depuis un conteneur (`i/o timeout`). D'où, dans les fragments
`.tls.` :

```
resolvers 1.1.1.1 8.8.8.8
propagation_delay 20s
propagation_timeout 5m
```

C'est ce qui sépare un certificat obtenu d'une boucle de `will retry`.

### 5.4 Navigateur qui garde une alerte périmée

Après avoir servi successivement plusieurs certificats sur le même nom (staging
puis production, ou un autre service auparavant), un navigateur peut conserver
un état d'erreur. Tester en navigation privée pour trancher. Si c'est bien ça :
`chrome://net-internals/#hsts` → *Delete domain security policies*. Sur Safari,
`rm ~/Library/Cookies/HSTS.plist` après avoir quitté l'application.

### 5.5 Un seul service par port

Il n'y a qu'un seul port 443 par IP publique. Deux services ne peuvent pas
l'occuper simultanément — le DNS n'y peut rien, il ne connaît que les adresses,
jamais les ports. Soit tout passe derrière certiac, soit le second service vit
sur un autre port et ses URLs le porteront.

---

## 6. Exploitation

### Sauvegarder — le point critique

Le volume `caddy_data` contient les certificats **et** la clé de compte ACME. Le
perdre force une réémission, et Let's Encrypt limite à 5 certificats par domaine
et par semaine.

```bash
docker run --rm -v certiac_caddy_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/caddy_data.tar.gz -C /data .
```

Restauration :

```bash
docker compose down
docker volume create certiac_caddy_data
docker run --rm -v certiac_caddy_data:/data -v "$PWD":/backup alpine \
  tar xzf /backup/caddy_data.tar.gz -C /data
docker compose up -d
```

### Consulter

```bash
docker compose logs -f caddy                     # tout
docker compose logs caddy | grep dynamic_dns     # DNS dynamique
tail -f logs/access.log                          # accès HTTP (JSON)
```

### Vérifier le DNS dynamique

```bash
curl -s https://icanhazip.com                    # doit être égal à...
dig +short @1.1.1.1 <ton-domaine>                # ...ceci
```

### Tester la rotation sans attendre 60 jours

En **staging uniquement** — en production ça consomme le quota :

```bash
docker compose exec caddy rm -rf /data/caddy/certificates
docker compose restart caddy
docker compose logs -f caddy   # doit réémettre immédiatement
```

### Diagnostic rapide

| Symptôme | Piste |
|---|---|
| `Restarting (1)` en boucle | token vide ou erreur de syntaxe — voir `docker compose logs caddy` |
| `will retry` sans fin | propagation DNS : voir §5.3 |
| Marche en local, pas de l'extérieur | redirection du routeur, ou port externe ≠ 443 |
| `000` depuis le LAN | la surcouche de test est active (écoute sur `127.0.0.1`) |
| « non sécurisé » sur un sous-domaine | cache navigateur, §5.4 |
| « non sécurisé » sur l'apex | normal si le wildcard est seul, §5.2 |
