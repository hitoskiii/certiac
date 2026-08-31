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
site/index.html                   page témoin servie en HTTPS
scripts/preflight.sh              contrôle .env avant démarrage
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

### 2.3 Contrôler la configuration avant de démarrer

```bash
./scripts/preflight.sh
```

Vérifie la présence de `.env`, les variables obligatoires, l'existence des
fragments du provider et surtout que **son secret est renseigné**. Un token vide
produit sinon `missing API token` et une boucle de redémarrage dont le message
n'est pas évident à relier à sa cause.

`.env` n'étant pas versionné, il est **absent après un `git clone`** : c'est
l'oubli le plus fréquent lors d'un déploiement sur une nouvelle machine.

### 2.4 Valider sans rien exposer

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

### 2.5 Passer en production

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

### 2.6 Fixer l'IP locale — ne pas sauter cette étape

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

### 2.7 Vérifier depuis l'extérieur

Le test local ne prouve rien sur le routeur. Depuis un téléphone en 4G, Wi-Fi
coupé :

```
https://home.<ton-domaine>
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

> À l'inverse, servir **l'apex seul** (sans wildcard) fonctionne très bien sur
> DuckDNS : un seul certificat, donc un seul TXT. Voir §7.4.

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

### 5.5 Après un `git pull`, recréer le conteneur

Docker bind-monte un **inode**, pas un chemin. Git ne modifie pas les fichiers
en place : il écrit un temporaire puis le renomme. Après un `git pull`, le
`Caddyfile` sur le disque est donc un **nouveau fichier**, tandis que le
conteneur reste attaché à l'ancien — qui n'existe plus que pour lui.

Symptôme déroutant : `grep` sur l'hôte montre la nouvelle config, `grep` dans le
conteneur montre l'ancienne. Ni `docker compose up -d` ni `caddy reload` n'y
changent quoi que ce soit, puisque le fichier lu est fidèlement l'ancien.

```bash
git pull
docker compose up -d --force-recreate     # sans nom de service : toute la stack
```

Vérifier ce que le conteneur voit réellement, jamais ce que voit l'hôte :

```bash
docker compose exec caddy grep -c '@seerr' /etc/caddy/Caddyfile
```

> Ne pas limiter la commande à `--force-recreate caddy` : les autres conteneurs
> resteraient à l'arrêt, et Caddy échouerait à les résoudre
> (`lookup <service>: server misbehaving`).

### 5.6 Un seul service par port

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
| `Restarting (1)` en boucle | lancer `./scripts/preflight.sh` — token vide dans 9 cas sur 10 |
| `missing API token` | `.env` absent (non versionné) ou secret non renseigné |
| `will retry` sans fin | propagation DNS : voir §5.3 |
| Marche en local, pas de l'extérieur | redirection du routeur, ou port externe ≠ 443 |
| `000` depuis le LAN | la surcouche de test est active (écoute sur `127.0.0.1`) |
| `connection reset by peer` vers un backend | trajet via `host.docker.internal` : préférer le réseau partagé (§7.4) |
| `lookup <service>: server misbehaving` | le conteneur visé n'est pas démarré — `docker compose up -d` sans nom de service |
| « non sécurisé » sur un sous-domaine | cache navigateur, §5.4 |
| « non sécurisé » sur l'apex | normal si le wildcard est seul, §5.2 |

---

## 7. Cas d'usage : Plex et demandes de films

Exposer un serveur Plex et une application de demandes (Overseerr, Jellyseerr,
Ombi) sur des sous-domaines en HTTPS. Le certificat wildcard les couvre tous les
deux sans émission supplémentaire.

### 7.1 Routes

Dans le `Caddyfile`, à l'intérieur du bloc `{$SITE_ADDRESSES}` :

```
	@plex host plex.{$DOMAIN}
	handle @plex {
		reverse_proxy 192.168.1.50:32400
	}

	@requests host requests.{$DOMAIN}
	handle @requests {
		reverse_proxy 192.168.1.50:5055
	}
```

L'adresse à viser dépend de la façon dont Plex est lancé. **C'est le point qui
fait perdre le plus de temps.**

| Situation | Cible à écrire |
|---|---|
| Plex en `network_mode: host`, **même machine** que certiac | `host.docker.internal:32400` |
| Plex sur une **autre machine** du réseau | `192.168.1.50:32400` (son IP locale) |
| Plex en réseau bridge, **rattaché au réseau `proxy`** | `plex:32400` (nom du service) |

Le premier cas est de loin le plus courant : les images Plex recommandent
`network_mode: host` pour la découverte DLNA et les clients du réseau local.
Conséquence, **Plex n'est pas sur le réseau `proxy`** et son nom de service ne
résout pas — viser `plex:32400` échouera avec `dial tcp: no such host`.

Le `docker-compose.yml` déclare pour cela :

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Ce nom existe d'office sur Docker Desktop (macOS, Windows) mais **pas sous
Linux**, où cette ligne le crée. Sans elle, un conteneur ne peut pas nommer son
hôte.

Troisième cas, si Plex tourne bien en bridge, il faut le rattacher au réseau :

```yaml
  plex:
    image: plexinc/pms-docker
    networks: [proxy]      # sans ça, Caddy ne le voit pas
```

Vérifier la connectivité avant de chercher ailleurs :

```bash
docker compose exec caddy wget -qO- --timeout=5 http://host.docker.internal:32400/identity
```

Une réponse XML contenant `machineIdentifier` = le chemin réseau est bon, et un
éventuel problème restant est côté réglages Plex (§7.2).

Caddy v2 relaie les WebSockets de façon transparente — aucune directive à
ajouter, contrairement à Caddy v1 qui demandait `websocket`. Il ne bufferise pas
non plus les réponses par défaut, ce qui est ce qu'on veut pour du streaming.

### 7.2 Réglages à faire dans Plex

Le proxy seul ne suffit pas : Plex doit être prévenu qu'on l'atteint par un
autre nom que le sien. Dans **Paramètres → Réseau** (afficher les réglages
avancés) :

| Réglage | Valeur |
|---|---|
| **Custom server access URLs** | `https://plex.mondomaine.fr:443` |
| **Secure connections** | `Preferred` (et non `Required`) |
| **LAN Networks** | ajouter le sous-réseau local, ex. `192.168.1.0/24` |

Pourquoi `Preferred` : par défaut Plex veut terminer lui-même le TLS avec son
certificat `*.plex.direct`. Derrière un proxy qui a déjà fait le travail, le
laisser sur `Required` provoque des erreurs de connexion.

Redémarrer le serveur Plex après ces changements.

> Les clients Plex (TV, mobile) privilégient souvent la découverte directe via
> les serveurs de Plex plutôt que l'URL personnalisée. Le proxy sert surtout au
> **client web** et aux accès depuis l'extérieur. Ce n'est pas un défaut de
> configuration.

### 7.3 Réglages côté application de demandes

Overseerr et Jellyseerr écoutent sur **5055**. Dans leurs paramètres généraux,
activer **« Enable proxy support »** (ou équivalent) pour qu'ils lisent
l'en-tête `X-Forwarded-For` que Caddy envoie — sans quoi tous les utilisateurs
apparaîtront avec l'IP du proxy, et les liens générés pointeront vers la
mauvaise adresse.

### 7.4 L'application de demandes

Elle est servie sur un **sous-domaine**, donc couverte par le certificat
wildcard — aucune émission supplémentaire :

```
https://seerr.sondomaine.fr
```

Deux variables la pilotent, sans toucher au `Caddyfile` :

```
SEERR_SUBDOMAIN=seerr                      # le label ; "requests" marche aussi
SEERR_UPSTREAM=host.docker.internal:5011   # le backend
```

**Le port à indiquer est celui publié sur l'hôte, pas celui du conteneur.**
C'est l'erreur la plus fréquente, parce que toute la documentation de ces
applications parle de 5055. `docker ps` donne les deux :

```
seerr   seerr/seerr:latest   0.0.0.0:5011->5055/tcp
                                      ▲        ▲
                              hôte ───┘        └─── interne au conteneur
```

Ici il faut **5011**. Vérifier le chemin réseau avant de suspecter autre chose :

```bash
docker compose exec caddy wget -qO- --timeout=5 http://host.docker.internal:5011/ | head -c 200
```

Du HTML en retour = Caddy atteint bien l'application.

**Mieux que `host.docker.internal` : le réseau partagé.** Passer par le port
publié sur l'hôte fonctionne, mais le trajet traverse `docker-proxy` et du NAT,
ce qui provoque des `connection reset by peer` sporadiques — l'application n'y
est pour rien, elle ne redémarre même pas.

Si l'application vit dans un autre projet compose, rattacher Caddy à son réseau
et la viser par son nom de conteneur. Trouver le réseau :

```bash
docker inspect seerr --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'
```

Puis, dans `docker-compose.yml`, décommenter les deux blocs prévus (service et
`networks`), en remplaçant `homedl_default` par le nom obtenu. Enfin :

```
SEERR_UPSTREAM=seerr:5055     # nom du conteneur + port INTERNE, plus celui de l'hôte
```

Le port change aussi : en direct on vise le port **interne** au conteneur
(5055), plus celui publié sur l'hôte (5011).

> Une réponse **307** sur la racine n'est pas une erreur : ces applications
> redirigent vers `/login` tant qu'on n'est pas authentifié.

**Variante — servir l'application sur l'apex.** C'est possible sur DuckDNS,
malgré le §5.1 : la limite du TXT unique ne se déclenche que si l'apex *et* le
wildcard sont demandés ensemble. Un apex seul, c'est un certificat, donc un TXT.
Il faut alors `SITE_ADDRESSES=sondomaine.duckdns.org` (sans astérisque) et
changer le matcher en `@seerr host {$DOMAIN}`. On renonce en échange à tous les
sous-domaines, donc à Plex — c'est l'un ou l'autre.

### 7.5 Ce qu'il ne faut PAS exposer

Overseerr et Jellyseerr ont une authentification et sont conçus pour être
ouverts à des utilisateurs. Ce n'est **pas** le cas des applications qui les
alimentent — Radarr, Sonarr, Prowlarr, qSonarr, le client de téléchargement.
Leur authentification est faible ou désactivée par défaut, et elles donnent un
accès direct au système de fichiers.

Ne créer aucune route vers elles. Le `handle { abort }` en fin de bloc garantit
qu'un sous-domaine non déclaré ne répond pas — mais la vraie protection, c'est
de ne pas écrire la route.

### 7.6 Récapitulatif pour la machine Plex

1. Docker installé sur la machine (§2.1)
2. Un domaine avec accès API — DuckDNS suffit et est gratuit (§2.2)
3. Valider en staging sans ouvrir de port (§2.4)
4. Redirection `443 -> <ip-locale>:HTTPS_PORT` sur le routeur (§2.6)
5. **Réservation DHCP** pour la machine Plex (§2.5) — sinon l'accès tombera
6. Routes Plex et demandes (§7.1), puis réglages internes (§7.2, §7.3)

---

## Licence

MIT — voir [LICENSE](LICENSE).
