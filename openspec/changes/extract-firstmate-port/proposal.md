# Change: Extract firstmate-port from the hub

## Why
The firstmate hub is moving to its own OSS-bound repository so the portal can ship without the Mac Discord notifier, without compiled-in site identity, and with Bazel plus a local compose stack.

## What Changes
- Rename firstmate hub to firstmate-port (OTP app, modules, images, k8s).
- Keep Phoenix/Ash portal, NATS cluster manifests, fm-steer, Archify hosting, GitHub poll, farm-roll API, MCP, OIDC, LiveView queues.
- Leave notify.py, watch.py, launchd, and Discord webhook sending in firstmate-notify.
- Scrub bot tokens, GITHUB_TOKEN values, Discord webhooks, live-system data, and compiled-in carverauto hostnames / VIP / allowlists. Those remain configuration examples only.
- Bazel with rules_elixir / BuildBuddy remote-exec patterns. Local output base `/tmp/fm-fm-port/bazel`.
- Docker Compose: portal + Postgres + NATS JetStream. Harbor publish documented; ghcr.io is a later public mirror.
- Tailwind v4 operator UI, Geist, one accent, light/dark.

## Impact
- Affected specs: `firstmate-portal`
- Affected code: this repository (new)
