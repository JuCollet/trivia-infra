# trivia-infra

Infrastructure de **Chacun son truc** : la VM Oracle Cloud (free tier), le cluster k3s, Argo CD et le tunnel Cloudflare qui publie `trivia-server`.

## Vue d'ensemble

```
Téléphones ──HTTPS──▶ <domaine>            Cloudflare Pages (trivia-client, statique)
Téléphones ─┐
App TV ─────┴─HTTPS/WSS─▶ api.<domaine> ─▶ Tunnel Cloudflare
                                               │ connexion sortante, aucun port ouvert
                                               ▼
                         ┌──────── VM Oracle Ampere A1 (arm64, free tier) ────────┐
                         │  k3s                                                   │
                         │   ├─ cloudflared ──▶ trivia-server (1 replica) ──▶ API Claude
                         │   └─ Argo CD ◀── surveille ce repo (GitOps)            │
                         └────────────────────────────────────────────────────────┘
```

Deux outils, deux rôles :

- **Terraform** (`terraform/`) crée ce qui est *autour* du cluster : réseau et VM chez Oracle, tunnel, DNS et projet Pages chez Cloudflare. On le lance à la main, rarement.
- **Argo CD** gère ce qui est *dans* le cluster : il applique en continu le contenu de `apps/`. Pour déployer, on modifie Git, pas le cluster.

Le passage de l'un à l'autre se fait au premier démarrage de la VM : cloud-init installe k3s, qui installe Argo CD, qui lit `argocd/apps/` et déploie le reste. Aucune commande `kubectl apply` à lancer.

## Structure

```
terraform/            VM, réseau, tunnel, DNS, Pages
  cloud-init.yaml.tftpl  premier démarrage : k3s + Argo CD + application racine
argocd/apps/          une Application Argo CD par composant (« app of apps »)
apps/
  trivia-server/      Deployment + Service, version de l'image dans kustomization.yaml
  cloudflared/        connecteur du tunnel
scripts/
  set-secrets.sh      crée les secrets dans le cluster (jamais dans Git)
  kubeconfig.sh       accès kubectl depuis ton Mac, par tunnel SSH
docs/
  deploiement-continu.md  ce qu'il faut ajouter aux CI de trivia-server et trivia-client
```

## Premier déploiement

### 1. Prérequis

- **Oracle Cloud** : dans la console, *Profil → Clés d'API → Ajouter une clé d'API*, puis copier le bloc de configuration proposé dans `~/.oci/config` (avec le chemin de la clé privée téléchargée). L'OCID de la tenancy sert de `compartment_ocid`.
- **Cloudflare** : un token d'API (*My Profile → API Tokens → Create Token → Custom*) avec les permissions :
  - *Account* : `Cloudflare Tunnel: Edit`, `Cloudflare Pages: Edit` ;
  - *Zone* (ta zone) : `DNS: Edit`, `Zone: Read`, `Zone WAF: Edit` (règle de rate limiting).
- **GitHub** : ce repo poussé sur `github.com/JuCollet/trivia-infra`, **public** (il ne contient aucun secret ; privé, Argo CD aurait besoin d'une clé de déploiement).
- Une clé SSH (`~/.ssh/id_ed25519.pub` par défaut).

### 2. Créer l'infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # puis remplir
export CLOUDFLARE_API_TOKEN=...
terraform init
terraform plan
terraform apply
```

L'erreur `Out of host capacity` est fréquente sur les instances A1 gratuites : réessayer plus tard, ou changer `availability_domain_index`.

### 3. Attendre l'installation (5 à 10 minutes)

```bash
ssh ubuntu@$(terraform output -raw public_ip) 'cloud-init status --wait && sudo k3s kubectl get applications -n argocd'
```

`trivia-server` et `cloudflared` apparaissent, en erreur tant que les secrets et l'image n'existent pas.

### 4. Créer les secrets

```bash
../scripts/set-secrets.sh
```

Le token du tunnel vient de l'état Terraform, la clé Anthropic est demandée (ou lue dans `ANTHROPIC_API_KEY`).

### 5. Publier l'image du serveur

Tant que la CI de `trivia-server` ne publie pas `ghcr.io/jucollet/trivia-server`, le pod reste en `ImagePullBackOff` : voir [docs/deploiement-continu.md](docs/deploiement-continu.md). Le paquet GHCR doit être public, ou il faudra un `imagePullSecret`.

Vérification : `curl https://api.<domaine>/actuator/health`.

## Au quotidien

| Je veux… | Je fais… |
|---|---|
| Déployer une nouvelle version du serveur | Rien : la CI de trivia-server met à jour `apps/trivia-server/kustomization.yaml`, Argo CD suit |
| Changer la config d'un composant | Modifier `apps/…`, commit, push |
| Voir l'état du cluster | `scripts/kubeconfig.sh`, puis `kubectl` ou `k9s` |
| Ouvrir l'UI Argo CD | Tunnel ouvert : `kubectl -n argocd port-forward svc/argo-cd-server 8081:80`, puis http://localhost:8081 (utilisateur `admin`, mot de passe : `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`) |
| Changer la clé Anthropic | `scripts/set-secrets.sh` |
| Repartir d'une VM neuve | `terraform apply -replace=oci_core_instance.k3s`, puis `scripts/set-secrets.sh` |

## Limites du free tier

- **Récupération des instances inactives** : Oracle peut arrêter une instance Always Free qui reste sous 20 % de CPU pendant 7 jours. Passer le compte en *Pay As You Go* (sans dépasser le gratuit, rien n'est facturé) supprime cette règle.
- Les ressources Always Free n'existent que dans la **région d'origine** de la tenancy.
- Une seule VM : un redémarrage coupe les parties en cours, comme prévu dans l'architecture du serveur.

## Plus tard

- État Terraform dans un bucket Object Storage (backend `oci`) plutôt qu'en local.
- Secrets dans Git, chiffrés (Sealed Secrets ou SOPS), à la place de `set-secrets.sh`.
- Argo CD qui se gère lui-même (son Helm chart comme Application).
- Restreindre `trivia.game.allowed-origin-patterns` à l'origine du client web, après avoir vérifié ce qu'envoie l'app TV.
- PostgreSQL quand le serveur en aura besoin.
