#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-firstmate}"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need kubectl
need openssl

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$(dirname "$0")/../k8s/namespace.yaml"

if kubectl -n "$NS" get secret firstmate-db-credentials >/dev/null 2>&1; then
  echo "reusing firstmate-db-credentials"
else
  PG_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  kubectl -n "$NS" create secret generic firstmate-db-credentials \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=firstmate \
    --from-literal=password="$PG_PASS"
fi

if kubectl -n "$NS" get secret firstmate-app >/dev/null 2>&1; then
  echo "reusing firstmate-app"
else
  kubectl -n "$NS" create secret generic firstmate-app \
    --from-literal=secret-key-base="$(openssl rand -hex 64)"
fi

if kubectl -n "$NS" get secret firstmate-agent >/dev/null 2>&1; then
  echo "reusing firstmate-agent"
else
  kubectl -n "$NS" create secret generic firstmate-agent \
    --from-literal=token="fmh_$(openssl rand -hex 24)"
fi

if kubectl -n "$NS" get secret firstmate-nats >/dev/null 2>&1; then
  echo "reusing firstmate-nats"
else
  kubectl -n "$NS" create secret generic firstmate-nats \
    --from-literal=token="$(openssl rand -hex 32)"
fi

echo "GitHub PAT (optional until poll is enabled):"
echo "  kubectl -n $NS create secret generic github-token --from-literal=GITHUB_TOKEN=<fine-grained-pat>"
echo "Discord interactions (captain):"
echo "  kubectl -n $NS create secret generic firstmate-discord --from-literal=public-key=<hex> --from-literal=bot-token=<token>"
echo "done. OIDC secret is created by deploy/bootstrap-authentik-oidc.sh"
