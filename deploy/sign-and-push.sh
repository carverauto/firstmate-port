#!/usr/bin/env bash
# Build, push, and sign the portal image.
# Harbor is the internal registry. ghcr.io is a later public mirror.
# Site-specific OpenBao/k8s names belong in env or deploy/examples, not here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="sha-$(git rev-parse HEAD)"
REGISTRY="${HARBOR_REGISTRY:-registry.example.com}"
PROJECT="${HARBOR_PROJECT:-firstmate}"
IMAGE="${REGISTRY}/${PROJECT}/firstmate-port"
DIGEST="${1:?usage: sign-and-push.sh sha256:<digest>}"
if [ "${COSIGN_KEY_REF:-}" = "" ]; then
  echo "set COSIGN_KEY_REF to sign, or push unsigned"
  docker push "${IMAGE}@${DIGEST}"
  exit 0
fi
if [ -n "${OPENBAO_NAMESPACE:-}" ] && [ -n "${SIGNING_SA_NAMESPACE:-}" ] && [ -n "${SIGNING_SA:-}" ]; then
  kubectl port-forward -n "${OPENBAO_NAMESPACE}" "${OPENBAO_SERVICE:-svc/openbao-active}" "${OPENBAO_LOCAL_PORT:-18200}:8200" >/tmp/firstmate-openbao-pf.log 2>&1 &
  PF_PID=$!
  trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
  sleep 2
  OPENBAO_ADDR="${OPENBAO_ADDR:-https://127.0.0.1:${OPENBAO_LOCAL_PORT:-18200}}"
  sa_jwt="$(kubectl create token -n "${SIGNING_SA_NAMESPACE}" "${SIGNING_SA}")"
  vault_token="$(curl -skS -H 'Content-Type: application/json' \
    -d "{\"role\":\"${SIGNING_SA}\",\"jwt\":\"${sa_jwt}\"}" \
    "${OPENBAO_ADDR}/v1/auth/kubernetes/login" | jq -er '.auth.client_token')"
  export VAULT_ADDR="$OPENBAO_ADDR" VAULT_TOKEN="$vault_token" VAULT_SKIP_VERIFY=true
fi
export COSIGN_YES=true COSIGN_TLOG_UPLOAD=true
cosign sign --key "$COSIGN_KEY_REF" "${IMAGE}@${DIGEST}"
crane tag "${IMAGE}@${DIGEST}" "$TAG"
echo "signed ${IMAGE}@${DIGEST} as ${TAG}"
