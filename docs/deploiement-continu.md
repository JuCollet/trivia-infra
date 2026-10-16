# Déploiement continu

Ce repo décrit *ce qui tourne*. Ce sont les CI des repos applicatifs qui produisent *ce qu'on déploie* :

| Repo | Ce que sa CI produit | Où ça va | Qui le déploie |
|---|---|---|---|
| trivia-server | une image `linux/arm64` | `ghcr.io/jucollet/trivia-server:<commit>` | la CI met à jour `apps/trivia-server/kustomization.yaml` ici, Argo CD suit |
| trivia-client | un site statique (`dist/`) | Cloudflare Pages, projet `trivia-client` | la CI elle-même (`wrangler pages deploy`) |
| trivia-tv | un APK Android TV | installé à la main sur le projecteur | personne : l'URL du serveur est figée au build |
| trivia-tv (web) | un site statique (`dist/`) | Cloudflare Pages, projet `trivia-tv`, servi sous `/tv` du client | la CI elle-même (`wrangler pages deploy`) |

Ce document décrit les jobs à ajouter dans les deux premiers repos et les secrets dont ils ont besoin.

## trivia-server : image, puis mise à jour de ce repo

```
push sur master ─▶ CI (tests) ─▶ image arm64 ─▶ GHCR ─▶ commit dans trivia-infra ─▶ Argo CD ─▶ nouveau pod
```

Le serveur n'a pas de Dockerfile : `spring-boot:build-image` construit l'image avec les buildpacks Paketo (JRE, utilisateur non root, réglages mémoire adaptés au conteneur).
La VM est en arm64 et les runners GitHub standard en amd64 : QEMU émule l'arm64 pendant la construction. C'est lent (quelques minutes) mais gratuit, et ne se fait qu'au merge sur master.

Job à ajouter à la fin de `.github/workflows/ci.yml` de trivia-server :

```yaml
  image:
    name: Image
    needs: server
    if: github.event_name == 'push' && github.ref == 'refs/heads/master'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    env:
      IMAGE: ghcr.io/jucollet/trivia-server
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: '25'
          cache: maven

      # Lets the amd64 runner execute the arm64 build steps
      - uses: docker/setup-qemu-action@v3

      - name: Build the arm64 image
        run: >
          ./mvnw --batch-mode spring-boot:build-image -DskipTests
          -Dspring-boot.build-image.imageName=$IMAGE:${{ github.sha }}
          -Dspring-boot.build-image.imagePlatform=linux/arm64

      - name: Push to GitHub Container Registry
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          docker push "$IMAGE:${{ github.sha }}"

  deploy:
    name: Deploy
    needs: image
    runs-on: ubuntu-latest
    steps:
      # The GITHUB_TOKEN of this repo cannot push to another repo: a fine-grained token limited to trivia-infra can
      - uses: actions/checkout@v7
        with:
          repository: JuCollet/trivia-infra
          token: ${{ secrets.INFRA_REPO_TOKEN }}

      - name: Point the deployment to the new image
        working-directory: apps/trivia-server
        run: kustomize edit set image ghcr.io/jucollet/trivia-server:${{ github.sha }}

      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "Deploy trivia-server ${{ github.sha }}"
          git push
```

Une fois le commit poussé, Argo CD le voit (il interroge Git toutes les 3 minutes) et remplace le pod. `strategy: Recreate` : l'ancien pod s'arrête avant que le nouveau démarre, donc les parties en cours sont coupées. Déployer entre deux soirées.

Pour revenir en arrière : `git revert` du commit « Deploy trivia-server … » dans ce repo.

### Ce qu'il faut configurer à la main

1. **Token `INFRA_REPO_TOKEN`** : GitHub → *Settings → Developer settings → Fine-grained tokens → Generate new token*, accès au seul repo `trivia-infra`, permission *Contents: Read and write*. Le coller dans trivia-server → *Settings → Secrets and variables → Actions*.
2. **Image publique** : après la première publication, *GitHub → Packages → trivia-server → Package settings → Change visibility → Public*. Le repo trivia-server est privé, donc l'image l'est aussi par défaut, et le cluster n'a pas d'identifiants pour la tirer. Elle ne contient que le serveur compilé, aucun secret (la clé Anthropic est injectée au démarrage). Sinon, il faut un `imagePullSecret` dans le namespace `trivia`.

## trivia-client : build, puis Cloudflare Pages

Le client parle au serveur à l'adresse `VITE_API_URL`, lue **au build** par Vite. Terraform l'affiche : `terraform output api_url`.

Workflow à ajouter dans trivia-client, `.github/workflows/ci.yml` :

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [master]

permissions:
  contents: read
  packages: read # @jucollet/trivia-client, published by trivia-server on GitHub Packages

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: npm

      - run: npm ci
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - run: npm run lint
      - run: npm test
      - run: npm run build
        env:
          VITE_API_URL: ${{ vars.API_URL }}

      - name: Deploy to Cloudflare Pages
        if: github.event_name == 'push' && github.ref == 'refs/heads/master'
        run: npx wrangler pages deploy dist --project-name=trivia-client --branch=master
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
```

### Ce qu'il faut configurer à la main

1. **Accès au paquet npm** : *GitHub → Packages → @jucollet/trivia-client → Package settings → Manage Actions access → Add repository → trivia-client* (lecture). Sans ça, `npm ci` échoue en 403 : le paquet appartient à trivia-server.
2. **Variables** (trivia-client → *Settings → Secrets and variables → Actions → Variables*) :
   - `API_URL` = `https://api.<domaine>` ;
   - `CLOUDFLARE_ACCOUNT_ID` = l'identifiant du compte Cloudflare (colonne de droite de la page d'accueil de la zone).
3. **Secret `CLOUDFLARE_API_TOKEN`** : un token Cloudflare distinct de celui de Terraform, avec la seule permission *Account → Cloudflare Pages: Edit*.

## trivia-tv : deux variables au build

L'app TV n'a pas de déploiement continu : on construit l'APK et on l'installe sur le projecteur. Avant le build, dans `.env` :

```
EXPO_PUBLIC_API_URL=https://api.<domaine>
EXPO_PUBLIC_JOIN_URL=https://<domaine>
```

`EXPO_PUBLIC_*` est figé dans le bundle : changer de domaine impose de reconstruire l'APK.
