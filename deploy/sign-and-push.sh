#!/usr/bin/env bash
# Build, push, and sign the portal image.
# Harbor is the internal registry. ghcr.io is a later public mirror.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="sha-$(git -C "$ROOT" rev-parse HEAD)"
REGISTRY="${HARBOR_REGISTRY:-registry.example.com}"
PROJECT="${HARBOR_PROJECT:-firstmate}"
IMAGE="${REGISTRY}/${PROJECT}/firstmate-port"
cd "$ROOT/hub"
# ko or docker build is environment-specific; this script signs a digest already in Harbor.
DIGEST="${1:?usage: sign-and-push.sh sha256:<digest>}"
if [ "${COSIGN_KEY_REF:-}" = "" ]; then echo "set COSIGN_KEY_REF to sign, or push unsigned"; docker push "${IMAGE}@${DIGEST}"; exit 0; fi
kubectl port-forward -n openbao-system svc/openbao-active 18200:8200 >/tmp/firstmate-openbao-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 2
OPENBAO_ADDR=https://127.0.0.1:18200
sa_jwt="$(kubectl create token -n forgejo-actions forgejo-signing-runner)"
vault_token="$(curl -skS -H 'Content-Type: application/json' \
  -d "{\"role\":\"forgejo-signing-runner\",\"jwt\":\"${sa_jwt}\"}" \
  "${OPENBAO_ADDR}/v1/auth/kubernetes/login" | jq -er '.auth.client_token')"
export VAULT_ADDR="$OPENBAO_ADDR" VAULT_TOKEN="$vault_token" VAULT_SKIP_VERIFY=true
export COSIGN_KEY_REF=hashivault://cosign-release COSIGN_YES=true COSIGN_TLOG_UPLOAD=true
cosign sign --key "$COSIGN_KEY_REF" "${IMAGE}@${DIGEST}"
crane tag "${IMAGE}@${DIGEST}" "$TAG"
echo "signed ${IMAGE}@${DIGEST} as ${TAG}"
