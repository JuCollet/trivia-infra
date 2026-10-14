#!/usr/bin/env bash
# Creates the secrets of the cluster, which never go through Git:
# - cloudflared/cloudflared: TUNNEL_TOKEN, read from the Terraform state;
# - trivia/trivia-server: ANTHROPIC_API_KEY, read from the environment or typed in.
# Values travel through the SSH standard input, never as command-line arguments. Safe to run again.
set -euo pipefail

cd "$(dirname "$0")/../terraform"
ip=$(terraform output -raw public_ip)
tunnel_token=$(terraform output -raw tunnel_token)

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  read -rsp "ANTHROPIC_API_KEY (empty: fallback questions only): " ANTHROPIC_API_KEY
  echo
fi

# apply_secret <namespace> <secret> <KEY> <value>
apply_secret() {
  printf '%s=%s\n' "$3" "$4" | ssh "ubuntu@$ip" "
    set -e
    kubectl() { sudo k3s kubectl \"\$@\"; }
    kubectl create namespace $1 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n $1 create secret generic $2 --from-env-file=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
    # Environment variables are read at startup: restart the pods if they already run
    if kubectl -n $1 get deployment $2 >/dev/null 2>&1; then kubectl -n $1 rollout restart deployment $2; fi
  "
}

apply_secret cloudflared cloudflared TUNNEL_TOKEN "$tunnel_token"
if [[ -n "$ANTHROPIC_API_KEY" ]]; then
  apply_secret trivia trivia-server ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
fi
