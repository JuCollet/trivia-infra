#!/usr/bin/env bash
# Gives kubectl, k9s and the Argo CD UI access to the cluster from your machine.
# The Kubernetes API is not exposed on the Internet: it goes through an SSH tunnel on port 6443.
set -euo pipefail

cd "$(dirname "$0")/../terraform"
ip=$(terraform output -raw public_ip)
kubeconfig="$HOME/.kube/trivia.yaml"

mkdir -p "$HOME/.kube"
# The k3s kubeconfig already points to https://127.0.0.1:6443, the local end of the tunnel
ssh "ubuntu@$ip" sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/: default$/: trivia/' > "$kubeconfig"
chmod 600 "$kubeconfig"

echo "Kubeconfig written to $kubeconfig. In another terminal:"
echo "  export KUBECONFIG=$kubeconfig"
echo "  kubectl get pods -A"
echo
echo "SSH tunnel open (Ctrl-C to close)..."
exec ssh -N -L 6443:127.0.0.1:6443 "ubuntu@$ip"
