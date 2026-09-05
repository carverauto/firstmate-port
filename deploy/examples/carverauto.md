# Example overlay: carverauto

These values are an example of a private deployment. They are not compiled into
the portal. Copy them into GitOps overlays, `.env`, or `docker-compose.override.yml`.

| Setting | Example |
| --- | --- |
| Portal hostname | `firstmate.carverauto.dev` |
| LAN VIP | `192.168.6.87` |
| Authentik issuer | `https://auth.carverauto.dev/application/o/firstmate/` |
| Image | `ghcr.io/mfreeman451/firstmate-port` |
| Discord interactions | `discord-firstmate.carverauto.dev` |
| Email allowlist | `@carverauto.dev` |
| BuildBuddy | `carverauto.buildbuddy.io` |

ghcr.io is the registry for this product; Harbor is not used. The source repo is
private, so the package is private and the namespace needs an `imagePullSecret`
(`ghcr-io-cred`, a `docker-registry` secret) built from a token with `read:packages`.

Gateways in this cluster:

| Route | Gateway | Section | Hostname |
| --- | --- | --- | --- |
| Portal (LAN only) | `lan-edge/lan-shared-gateway` (VIP `192.168.6.87`) | `https-carverauto` / `http-carverauto` | `firstmate.carverauto.dev` |
| Discord interactions | `serviceradar-system/serviceradar-shared-gateway` | `https-carverauto` | `discord-firstmate.carverauto.dev`, path-only `/interactions` |

The namespace needs both gateway selector labels:
`carverauto.com/lan-gateway-access=true` and `serviceradar.com/gateway-access=true`.

A ready-to-apply kustomize overlay of exactly this table is in
[`carverauto/`](carverauto/). It is an example overlay, never a compiled-in default.
