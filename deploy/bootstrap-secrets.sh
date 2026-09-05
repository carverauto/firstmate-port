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

# CNPG does not create a <cluster>-app secret when bootstrap.initdb.secret is
# supplied, so build the DATABASE_URL the Deployment reads from the credentials
# above. Passwords generated here are alphanumeric, so no URL escaping is needed.
PG_CLUSTER="${PG_CLUSTER:-firstmate-pg}"
PG_DB="${PG_DB:-firstmate}"
PG_USER="$(kubectl -n "$NS" get secret firstmate-db-credentials -o jsonpath='{.data.username}' | base64 -d)"
PG_PASSWORD="$(kubectl -n "$NS" get secret firstmate-db-credentials -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n "$NS" create secret generic "${PG_CLUSTER}-app" \
  --from-literal=uri="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_CLUSTER}-rw:5432/${PG_DB}" \
  --from-literal=username="${PG_USER}" \
  --from-literal=password="${PG_PASSWORD}" \
  --from-literal=dbname="${PG_DB}" \
  --from-literal=host="${PG_CLUSTER}-rw" \
  --from-literal=port="5432" \
  --dry-run=client -o yaml | kubectl apply -f -

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

# Encrypts every tenant credential typed into the portal. Losing it means every
# stored credential has to be re-entered, so back it up with the database.
if kubectl -n "$NS" get secret firstmate-cloak >/dev/null 2>&1; then
  echo "reusing firstmate-cloak"
else
  kubectl -n "$NS" create secret generic firstmate-cloak \
    --from-literal=key="$(openssl rand -base64 32)"
fi

if kubectl -n "$NS" get secret firstmate-nats >/dev/null 2>&1; then
  echo "reusing firstmate-nats"
else
  kubectl -n "$NS" create secret generic firstmate-nats \
    --from-literal=token="$(openssl rand -hex 32)"
fi

echo "GitHub PAT (optional until poll is enabled):"
echo "  kubectl -n $NS create secret generic github-token --from-literal=GITHUB_TOKEN=<fine-grained-pat>"
echo "Discord and other per-tenant credentials are NOT kubectl secrets."
echo "  Each tenant enters its own at https://<host>/settings/credentials"
echo "  or through PUT /api/credentials/<provider>/<key>. See docs/credentials.md."
echo "done. OIDC secret is created by deploy/bootstrap-authentik-oidc.sh"
