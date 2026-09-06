# Example overlay: carverauto

These values are an example of a private deployment. They are not compiled into
the portal. Copy them into GitOps overlays, `.env`, or `docker-compose.override.yml`.

| Setting | Example |
| --- | --- |
| Portal hostname | `firstmate.carverauto.dev` |
| LAN VIP | `192.168.6.87` |
| OIDC issuer (Authentik) | `https://auth.carverauto.dev/application/o/firstmate/` |
| Image | `ghcr.io/carverauto/firstmate-port` |
| Discord interactions | `discord-firstmate.carverauto.dev` |
| Local sign-in | `LOCAL_AUTH=true`; provision credentials with the command below (see [Sign-in](../../docs/deploy.md#sign-in)) |
| BuildBuddy | `carverauto.buildbuddy.io` |

ghcr.io is the registry for this product; Harbor is not used. The namespace pulls
with an `imagePullSecret` (`ghcr-io-cred`, a `docker-registry` secret).

Gateways in this cluster:

| Route | Gateway | Section | Hostname |
| --- | --- | --- | --- |
| Portal (LAN only) | `lan-edge/lan-shared-gateway` (VIP `192.168.6.87`) | `https-carverauto` / `http-carverauto` | `firstmate.carverauto.dev` |
| Discord interactions | `serviceradar-system/serviceradar-shared-gateway` | `https-carverauto` | `discord-firstmate.carverauto.dev`, path-only `/interactions` |

The namespace needs both gateway selector labels:
`carverauto.com/lan-gateway-access=true` and `serviceradar.com/gateway-access=true`.

A ready-to-apply kustomize overlay of exactly this table is in
[`carverauto/`](carverauto/). It is an example overlay, never a compiled-in default.

With kubectl targeting the `carverauto` context, provision or backfill its secrets
from the repository root:

```sh
bash deploy/examples/carverauto/bootstrap-secrets.sh
```

The wrapper sets `ADMIN_EMAIL=captain@localhost`. See
[Sign-in](../../docs/deploy.md#sign-in) for secret creation, password-preserving
email backfill, and account authentication. The command does not print secret
values.

Authentik is this site's identity provider, not the portal's. The portal speaks
generic OpenID Connect and reads its endpoints from the issuer's discovery
document, so swapping in Keycloak, Dex, Google, Okta, or Entra means changing
`OIDC_ISSUER` and the client credentials, nothing else.
[`carverauto/bootstrap-authentik-oidc.sh`](carverauto/bootstrap-authentik-oidc.sh)
provisions the client for this particular provider.
