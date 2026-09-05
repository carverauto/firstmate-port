# Deploy

## Local

```sh
cp .env.example .env
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker compose up --build
```

OpenSSL generates a 64-character secret without compiling Mix dependencies. The
export makes it available to Compose in this shell; save the generated value as
`SECRET_KEY_BASE` in `.env` to reuse it across shell sessions. Host-side
`mix deps.get` is not required for the Docker Compose build.

Avoid capturing `mix phx.gen.secret` with `$(...)` during initial setup: Mix may
compile dependencies to load the task, and command substitution hides standard
output (including compilation progress) while warnings remain visible on stderr.

Open http://localhost:4000/login. With `DEV_AUTH=true`, sign in as `captain@localhost`.

CLI (HTTP only, no NATS):

```sh
fm-steer auth login --instance http://localhost:4000
fm-steer inbox put --task fm-port --body "hello"
```

Crew shape against the live portal (default instance
`https://firstmate.carverauto.dev`; a bare `put` files under task
`firstmate`, and `next` with no `--task` takes the next item from the one
shared inbox — there is no second inbox):

```sh
fm-steer auth login
fm-steer inbox put --body "hello from second mate"
fm-steer inbox next
fm-steer inbox ack --ack <ack-from-next>
fm-steer inbox list
```

Postgres and NATS JetStream (single node, one account) are in the compose file. Streams are named `<tenant>.steer` and `<tenant>.inbound`. The Kubernetes NATS shape is a 3-node cluster (headless service, port 6222, PVCs, durable streams).

To run Mix against compose Postgres/NATS only:

```sh
docker compose up postgres nats
mix setup
mix phx.server
```

## Images

ghcr.io is the registry. `.github/workflows/publish-oci.yml` builds with Bazel and
pushes `ghcr.io/<owner>/firstmate-port` on `v*` tags and on `workflow_dispatch`,
authenticating with the workflow `GITHUB_TOKEN` (`permissions: packages: write`).
There are no registry robot secrets and no cosign/OpenBao requirement. Do not
invent a second forge.

Tags: `sha-<short-commit>` on every publish, plus the `v*` tag name on tag pushes.

```sh
docker build -t firstmate-port:local .
# Manual publish (CI is the normal path):
export OCI_PROJECT=<github-owner>
# docker tag firstmate-port:local ghcr.io/$OCI_PROJECT/firstmate-port:sha-$(git rev-parse --short HEAD)
# docker push ghcr.io/$OCI_PROJECT/firstmate-port:sha-$(git rev-parse --short HEAD)
./deploy/sign-and-push.sh sha256:<digest>
```

If the source repository is private the package is private too, so the cluster
needs an `imagePullSecret` built from a token with `read:packages`:

```sh
kubectl -n firstmate create secret docker-registry ghcr-io-cred \
  --docker-server=ghcr.io --docker-username=<github-user> --docker-password=<token>
```

Site-specific hostnames, Authentik URLs, allowlists, and ghcr namespaces live in:

- `.env` / `docker-compose.override.yml` (from the `.example` files)
- `deploy/examples/` notes
- Kubernetes secrets created by `deploy/bootstrap-secrets.sh`

They are not compiled-in defaults.

## Kubernetes

`k8s/` is a generic firstmate namespace: CNPG, 3-replica NATS JetStream, portal Deployment, HTTPRoute to `firstmate.example.com`. Overlay real hostnames and registry tags in your GitOps repo.

```sh
kubectl apply -k k8s
./deploy/bootstrap-secrets.sh
# optional OIDC: ./deploy/bootstrap-authentik-oidc.sh
```

`fm-steer` is the HTTP inbox port (`put` / `next` / `ack` / `list`). It does not dial NATS. The Phoenix API is the only JetStream client. The on-disk firstmate inbox stays until dual-write is wired.
