#!/usr/bin/env bash
# Example only: provisions an OIDC client in Authentik, one provider among many.
#
# The portal itself has no Authentik adapter. It speaks generic OpenID Connect
# and reads every endpoint from the issuer's discovery document, so the same
# portal works against Keycloak, Dex, Google, Okta, or Entra. Whatever you use,
# the portal needs only OIDC_ISSUER plus a client id and secret in the
# `firstmate-oidc` secret. Write the equivalent of this script for your own
# provider, or create that secret by hand.
set -euo pipefail

: "${AUTHENTIK_NAMESPACE:=authentik}"
: "${AUTHENTIK_SERVER_DEPLOYMENT:=authentik-server}"
: "${FIRSTMATE_NAMESPACE:=firstmate}"
: "${FIRSTMATE_OIDC_SECRET:=firstmate-oidc}"
: "${FIRSTMATE_OIDC_CLIENT_ID:=firstmate}"
: "${FIRSTMATE_OIDC_APP_SLUG:=firstmate}"
: "${FIRSTMATE_OIDC_REDIRECT_URI:=https://firstmate.example.com/auth/oidc/callback}"

if client_secret="$(
  kubectl -n "${FIRSTMATE_NAMESPACE}" get secret "${FIRSTMATE_OIDC_SECRET}" \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d
)"; then
  :
else
  client_secret="$(openssl rand -hex 32)"
fi

kubectl exec -i -n "${AUTHENTIK_NAMESPACE}" "deploy/${AUTHENTIK_SERVER_DEPLOYMENT}" -- \
  env \
    FIRSTMATE_OIDC_CLIENT_ID="${FIRSTMATE_OIDC_CLIENT_ID}" \
    FIRSTMATE_OIDC_CLIENT_SECRET="${client_secret}" \
    FIRSTMATE_OIDC_APP_SLUG="${FIRSTMATE_OIDC_APP_SLUG}" \
    FIRSTMATE_OIDC_REDIRECT_URI="${FIRSTMATE_OIDC_REDIRECT_URI}" \
  ak shell <<'PY'
import os

from authentik.common.oauth.constants import SubModes
from authentik.core.models import Application
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow
from authentik.providers.oauth2.models import (
    ClientTypes,
    IssuerMode,
    OAuth2Provider,
    RedirectURIMatchingMode,
    ScopeMapping,
)

client_id = os.environ["FIRSTMATE_OIDC_CLIENT_ID"]
client_secret = os.environ["FIRSTMATE_OIDC_CLIENT_SECRET"]
app_slug = os.environ["FIRSTMATE_OIDC_APP_SLUG"]
redirect_uri = os.environ["FIRSTMATE_OIDC_REDIRECT_URI"]

authorization_flow = Flow.objects.get(slug="default-provider-authorization-implicit-consent")
invalidation_flow = Flow.objects.get(slug="default-provider-invalidation-flow")
signing_key = (
    CertificateKeyPair.objects.filter(name="authentik Self-signed Certificate").first()
    or CertificateKeyPair.objects.first()
)

property_mappings = list(
    ScopeMapping.objects.filter(
        managed__in=[
            "goauthentik.io/providers/oauth2/scope-openid",
            "goauthentik.io/providers/oauth2/scope-email",
            "goauthentik.io/providers/oauth2/scope-profile",
        ]
    )
)

provider, _ = OAuth2Provider.objects.update_or_create(
    client_id=client_id,
    defaults={
        "name": "Provider for firstmate",
        "authorization_flow": authorization_flow,
        "invalidation_flow": invalidation_flow,
        "client_type": ClientTypes.CONFIDENTIAL,
        "client_secret": client_secret,
        "_redirect_uris": [
            {
                "matching_mode": RedirectURIMatchingMode.STRICT.value,
                "url": redirect_uri,
            }
        ],
        "include_claims_in_id_token": True,
        "sub_mode": SubModes.USER_EMAIL,
        "issuer_mode": IssuerMode.PER_PROVIDER,
        "signing_key": signing_key,
    },
)
provider.property_mappings.set(property_mappings)

application, _ = Application.objects.update_or_create(
    slug=app_slug,
    defaults={
        "name": "firstmate",
        "provider": provider,
        "group": "Infrastructure",
        "meta_description": "OIDC login for the firstmate / Archify portal (LAN).",
        "open_in_new_tab": True,
        "policy_engine_mode": "any",
    },
)

print(
    {
        "application": application.slug,
        "provider": provider.name,
        "client_id": provider.client_id,
        "redirect_uri": redirect_uri,
    }
)
PY

kubectl -n "${FIRSTMATE_NAMESPACE}" create secret generic "${FIRSTMATE_OIDC_SECRET}" \
  --from-literal=client-id="${FIRSTMATE_OIDC_CLIENT_ID}" \
  --from-literal=client-secret="${client_secret}" \
  --dry-run=client -o yaml | kubectl apply -f -
