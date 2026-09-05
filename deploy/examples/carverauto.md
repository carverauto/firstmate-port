# Example overlay: carverauto

These values are an example of a private deployment. They are not compiled into
the portal. Copy them into GitOps overlays, `.env`, or `docker-compose.override.yml`.

| Setting | Example |
| --- | --- |
| Portal hostname | `firstmate.carverauto.dev` |
| LAN VIP | `192.168.6.87` |
| Authentik issuer | `https://auth.carverauto.dev/application/o/firstmate/` |
| Harbor | `registry.carverauto.dev/carverauto/firstmate-port` |
| Discord interactions | `discord-firstmate.carverauto.dev` |
| Email allowlist | `@carverauto.dev` |
| BuildBuddy | `carverauto.buildbuddy.io` |

Harbor stays the internal registry. ghcr.io is a later public mirror.
