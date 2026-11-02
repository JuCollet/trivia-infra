# Continuous deployment

This repo describes *what runs*. The CIs of the application repos produce *what gets deployed*:

| Repo | What its CI produces | Where it goes | Who deploys it |
|---|---|---|---|
| trivia-server | a `linux/arm64` image | `ghcr.io/jucollet/trivia-server:<commit>` | the CI updates `apps/trivia-server/kustomization.yaml` here, Argo CD follows |
| trivia-client | a static site (`dist/`) | Cloudflare Pages, project `trivia-client` | the CI itself (`wrangler pages deploy`) |
| trivia-tv | an Android TV APK | installed by hand on the projector | nobody: the server URL is baked in at build time |
| trivia-tv (web) | a static site (`dist/`) | Cloudflare Pages, project `trivia-tv`, served under the client's `/tv` | the CI itself (`wrangler pages deploy`) |

This document describes the jobs to add to the first two repos and the secrets they need.

## trivia-server: image, then update of this repo

```
push to master ─▶ CI (tests) ─▶ arm64 image ─▶ GHCR ─▶ commit in trivia-infra ─▶ Argo CD ─▶ new pod
```

The server has no Dockerfile: `spring-boot:build-image` builds the image with the Paketo buildpacks (JRE, non-root user, memory settings tuned for the container).
The VM is arm64 and the standard GitHub runners are amd64: QEMU emulates arm64 during the build. It is slow (a few minutes) but free, and only happens on merge to master.

Job to add at the end of `.github/workflows/ci.yml` in trivia-server:

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

Once the commit is pushed, Argo CD sees it (it polls Git every 3 minutes) and replaces the pod. With `strategy: Recreate`, the old pod stops before the new one starts, so running games are cut. Deploy between two game nights.

To roll back: `git revert` the "Deploy trivia-server …" commit in this repo.

### Manual setup

1. **`INFRA_REPO_TOKEN` token**: GitHub → *Settings → Developer settings → Fine-grained tokens → Generate new token*, access to the `trivia-infra` repo only, permission *Contents: Read and write*. Paste it in trivia-server → *Settings → Secrets and variables → Actions*.
2. **Public image**: after the first publication, *GitHub → Packages → trivia-server → Package settings → Change visibility → Public*. The trivia-server repo is private, so the image is private by default too, and the cluster has no credentials to pull it. It only holds the compiled server, no secret (the Anthropic key is injected at startup). Otherwise, an `imagePullSecret` is needed in the `trivia` namespace.

## trivia-client: build, then Cloudflare Pages

The client talks to the server at `VITE_API_URL`, read **at build time** by Vite. Terraform prints it: `terraform output api_url`.

Workflow to add in trivia-client, `.github/workflows/ci.yml`:

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

### Manual setup

1. **Access to the npm package**: *GitHub → Packages → @jucollet/trivia-client → Package settings → Manage Actions access → Add repository → trivia-client* (read). Without it, `npm ci` fails with a 403: the package belongs to trivia-server.
2. **Variables** (trivia-client → *Settings → Secrets and variables → Actions → Variables*):
   - `API_URL` = `https://api.<domain>`;
   - `CLOUDFLARE_ACCOUNT_ID` = the Cloudflare account ID (right-hand column of the zone's overview page).
3. **`CLOUDFLARE_API_TOKEN` secret**: a Cloudflare token separate from the Terraform one, with only the *Account → Cloudflare Pages: Edit* permission.

## trivia-tv: two build-time variables

The TV app has no continuous deployment: you build the APK and install it on the projector. Before the build, in `.env`:

```
EXPO_PUBLIC_API_URL=https://api.<domain>
EXPO_PUBLIC_JOIN_URL=https://<domain>
```

`EXPO_PUBLIC_*` is baked into the bundle: changing the domain requires rebuilding the APK.
