# Build tracking

This page covers the system-specific Fleet-log tracks. For crew-reported
start/finish runs through `fm-steer build`, see [build events](build-events.md).

Kubernetes rolls, Docker builds, and BuildBuddy invocations are each
**opt-in**. When a track is not configured its Fleet-log plate and tab are
hidden entirely; the portal never renders an empty placeholder for it.

## Switches

| Track      | Plate | Enable with |
| ---------- | ----- | ----------- |
| Kubernetes | `?tab=kubernetes` | `KUBERNETES_TRACKING_ENABLED=true` |
| Docker     | `?tab=docker` | `DOCKER_TRACKING_ENABLED=true` |
| BuildBuddy | `?tab=buildbuddy` | Org key via the secret setup below |

Recorded facts stay generic: cluster/namespace/image/helm for Kubernetes,
registry repository/tag/digest for Docker (push to `ghcr.io` when you
mention an image), invocation id/host/status for BuildBuddy. There is no
farm-specific naming anywhere in the product.

## BuildBuddy org API key

This is a deployment-wide key shared by the portal's BuildBuddy client,
separate from tenant credentials stored in the portal.

Set `BUILDBUDDY_HOST` to your BuildBuddy endpoint for API lookups.
Compose defaults to `https://app.buildbuddy.io`; Kubernetes has no default.
The key alone enables recording and the Fleet-log plate, but lookups also
require the host.

Environment settings are loaded by the production release. For local
`mix phx.server`, configure `:firstmate_port, :build_tracking` in the dev
configuration instead; `.env` is consumed by Compose.

1. In your BuildBuddy org go to **Settings → Org API keys** and mint a key
   with invocation read access.
2. Treat the key as a secret. It is never committed and never logged; the
   app only sends it as the `x-buildbuddy-api-key` header.

### Compose (Docker secret)

Save only the org key in `.local-secrets/buildbuddy_org_api_key` (an ignored
directory). The portal image runs as UID 1000. On Linux with rootful Docker
and no user-namespace remapping, give that UID ownership and owner-only
read access before starting the portal:

```sh
sudo chown 1000 .local-secrets/buildbuddy_org_api_key
sudo chmod 0400 .local-secrets/buildbuddy_org_api_key
```

Apply these permissions again when replacing the key file. With rootless
Docker or user-namespace remapping, use the host UID mapped to container
UID 1000 instead. The mounted file must be readable by the container's
UID 1000; a root-owned file with mode 0600 prevents the portal from starting.
Compose uses a bind mount for file-backed secrets and ignores secret
`uid`, `gid`, and `mode` settings, so set ownership and permissions on the
host file itself. See [Docker's secret documentation](https://docs.docker.com/reference/compose-file/services/#secrets).

Set `BUILDBUDDY_HOST` in `.env` if needed, along with
the independent `KUBERNETES_TRACKING_ENABLED` and
`DOCKER_TRACKING_ENABLED` switches.

Start or recreate the portal with the secret override:

```sh
docker compose -f docker-compose.yml -f docker-compose.buildbuddy.yml up -d --build
```

The override mounts the file at `/run/secrets/buildbuddy_org_api_key`;
the app reads it through `BUILDBUDDY_ORG_API_KEY_FILE`. To use another
source file, set that variable in `.env`. The default Compose stack
requires no secret and leaves BuildBuddy tracking disabled. To disable
it again, recreate the portal using only `docker-compose.yml`.

### Kubernetes (firstmate namespace)

Create the secret (also printed by `deploy/bootstrap-secrets.sh`):

```sh
kubectl -n firstmate create secret generic firstmate-buildbuddy \
  --from-literal=org-api-key='PASTE_ORG_KEY_HERE'
```

`k8s/deployment.yaml` already maps that secret to
`BUILDBUDDY_ORG_API_KEY` with `optional: true`, so the Deployment works
with or without it. Uncomment `BUILDBUDDY_HOST` for API lookups. Enable
Kubernetes and Docker independently with their commented switches in the
same file, then apply the Deployment. After creating or rotating the
secret, restart existing pods so they receive the new environment:

```sh
kubectl -n firstmate rollout restart deployment/firstmate-port
```

## Recording

All writes need an agent token (`Authorization: Bearer <agent token>`).
Disabled tracks reject writes through both HTTP and MCP.

```sh
# Kubernetes roll (POST /api/rolls)
curl -X POST "$PUBLIC_URL/api/rolls" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"cluster":"prod","namespace":"web","status":"success","image_tag":"sha-abc123"}'

# Docker build (POST /api/docker-builds)
curl -X POST "$PUBLIC_URL/api/docker-builds" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"repository":"ghcr.io/example/app","tag":"sha-abc123","status":"success"}'

# BuildBuddy invocation (POST /api/buildbuddy-invocations)
curl -X POST "$PUBLIC_URL/api/buildbuddy-invocations" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"invocation_id":"abc-123","status":"SUCCESS"}'
```

The corresponding write/list MCP tools are `post_roll` / `list_rolls`,
`post_docker_build` / `list_docker_builds`, `post_buildbuddy_invocation` /
`list_buildbuddy_invocations`.

Recording stores the supplied fields; it does not query BuildBuddy or
automatically collect builds. Use the Elixir client below to fetch invocation
details before submitting a record.

## Querying BuildBuddy from Elixir

`FirstmatePort.BuildBuddy` (Req-based) calls
`POST {host}/rpc/BuildBuddyService/GetInvocation`
with proto3 JSON whenever the org key is present:

```elixir
alias FirstmatePort.BuildBuddy

BuildBuddy.configured?()
#=> true

{:ok, inv} = BuildBuddy.get_invocation("abc-123")
inv.status      #=> "SUCCESS"
inv.commit_sha  #=> "deadbeef"
inv.url         #=> "https://app.buildbuddy.io/invocation/abc-123"
```

Without a key every lookup returns `{:error, :unconfigured}`; without a
host, `{:error, :no_host}`. API calls use `BUILDBUDDY_HOST`.

Note: the GitHub poll copies a BuildBuddy invocation URL from check runs
onto `github_items.buildbuddy_url`. That is a copied link, not an API
client; only this module talks to the BuildBuddy API.
