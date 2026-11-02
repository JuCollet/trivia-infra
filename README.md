# trivia-infra

Infrastructure of **Chacun son truc**: the Oracle Cloud VM (free tier), the k3s cluster, Argo CD and the Cloudflare tunnel that publishes `trivia-server`.

## Overview

```
Phones ─────HTTPS──▶ <domain>              Cloudflare Pages (trivia-client, static)
Browser ────HTTPS──▶ <domain>/tv           relayed to Cloudflare Pages (trivia-tv, web version of the screen)
Phones ─────┐
TV app ─────┴─HTTPS/WSS─▶ api.<domain> ──▶ Cloudflare Tunnel
                                               │ outbound connection, no open port
                                               ▼
                         ┌──────── Oracle Ampere A1 VM (arm64, free tier) ────────┐
                         │  k3s                                                   │
                         │   ├─ cloudflared ──▶ trivia-server (1 replica) ──▶ Claude API
                         │   └─ Argo CD ◀── watches this repo (GitOps)            │
                         └────────────────────────────────────────────────────────┘
```

Two tools, two roles:

- **Terraform** (`terraform/`) creates what is *around* the cluster: network and VM at Oracle, tunnel, DNS and Pages project at Cloudflare. It is run by hand, rarely.
- **Argo CD** manages what is *inside* the cluster: it continuously applies the content of `apps/`. To deploy, you change Git, not the cluster.

The handover from one to the other happens at the first boot of the VM: cloud-init installs k3s, which installs Argo CD, which reads `argocd/apps/` and deploys the rest. No `kubectl apply` to run.

## Layout

```
terraform/            VM, network, tunnel, DNS, Pages
  cloud-init.yaml.tftpl  first boot: k3s + Argo CD + root application
argocd/apps/          one Argo CD Application per component ("app of apps")
apps/
  trivia-server/      Deployment + Service, image version in kustomization.yaml
  cloudflared/        tunnel connector
scripts/
  set-secrets.sh      creates the secrets in the cluster (never in Git)
  kubeconfig.sh       kubectl access from your Mac, through an SSH tunnel
docs/
  continuous-deployment.md  what to add to the CI of trivia-server and trivia-client
```

## First deployment

### 1. Prerequisites

- **Oracle Cloud**: in the console, *Profile → API keys → Add API key*, then copy the suggested configuration block into `~/.oci/config` (with the path of the downloaded private key). The tenancy OCID is used as `compartment_ocid`.
- **Cloudflare**: an API token (*My Profile → API Tokens → Create Token → Custom*) with the permissions:
  - *Account*: `Cloudflare Tunnel: Edit`, `Cloudflare Pages: Edit`;
  - *Zone* (your zone): `DNS: Edit`, `Zone: Read`, `Zone WAF: Edit` (rate limiting rule).
- **GitHub**: this repo pushed to `github.com/JuCollet/trivia-infra`, **public** (it holds no secret; if private, Argo CD would need a deploy key).
- An SSH key (`~/.ssh/id_ed25519.pub` by default).

### 2. Create the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill in
export CLOUDFLARE_API_TOKEN=...
terraform init
terraform plan
terraform apply
```

The `Out of host capacity` error is common on free A1 instances: try again later, or change `availability_domain_index`.

### 3. Wait for the installation (5 to 10 minutes)

```bash
ssh ubuntu@$(terraform output -raw public_ip) 'cloud-init status --wait && sudo k3s kubectl get applications -n argocd'
```

`trivia-server` and `cloudflared` show up, in error until the secrets and the image exist.

### 4. Create the secrets

```bash
../scripts/set-secrets.sh
```

The tunnel token comes from the Terraform state, the Anthropic key is prompted for (or read from `ANTHROPIC_API_KEY`).

### 5. Publish the server image

Until the CI of `trivia-server` publishes `ghcr.io/jucollet/trivia-server`, the pod stays in `ImagePullBackOff`: see [docs/continuous-deployment.md](docs/continuous-deployment.md). The GHCR package must be public, otherwise an `imagePullSecret` is needed.

Check: `curl https://api.<domain>/actuator/health`.

## Day to day

| I want to… | I do… |
|---|---|
| Deploy a new server version | Nothing: the CI of trivia-server updates `apps/trivia-server/kustomization.yaml`, Argo CD follows |
| Change the config of a component | Edit `apps/…`, commit, push |
| See the state of the cluster | `scripts/kubeconfig.sh`, then `kubectl` or `k9s` |
| Open the Argo CD UI | With the tunnel open: `kubectl -n argocd port-forward svc/argo-cd-server 8081:80`, then http://localhost:8081 (user `admin`, password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`) |
| Change the Anthropic key | `scripts/set-secrets.sh` |
| Start over from a fresh VM | `terraform apply -replace=oci_core_instance.k3s`, then `scripts/set-secrets.sh` |

## Free tier limits

- **Idle instance reclamation**: Oracle can stop an Always Free instance that stays under 20% CPU for 7 days. Upgrading the account to *Pay As You Go* (nothing is billed as long as you stay within the free tier) removes this rule.
- Always Free resources only exist in the tenancy's **home region**.
- A single VM: a reboot cuts the running games, as planned in the server architecture.

## Later

- Terraform state in an Object Storage bucket (`oci` backend) instead of locally.
- Secrets in Git, encrypted (Sealed Secrets or SOPS), instead of `set-secrets.sh`.
- Argo CD managing itself (its Helm chart as an Application).
- Restrict `trivia.game.allowed-origin-patterns` to the web client's origin, after checking what the TV app sends.
- PostgreSQL when the server needs it.
