# Example overlay: carverauto

These values are an example of a public deployment. They are not compiled into
the portal. Copy them into GitOps overlays, `.env`, or `docker-compose.override.yml`.

| Setting | Example |
| --- | --- |
| Portal hostname | `firstmate.carverauto.dev` (public, Cloudflare-proxied) |
| LAN VIP (previous gateway) | `192.168.6.87` |
| OIDC issuer (Authentik) | `https://auth.carverauto.dev/application/o/firstmate/` |
| Image | `ghcr.io/carverauto/firstmate-port` |
