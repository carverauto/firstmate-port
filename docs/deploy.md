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

Open http://localhost:4000/login and sign in with the account the portal
printed on first boot:

```sh
docker compose logs portal | grep -A4 "first-run sign-in"
```

No identity provider is required in any runtime.

CLI (HTTP only, no NATS):

```sh
fm-steer auth login --instance http://localhost:4000
fm-steer inbox put --task fm-port --body "hello"
```

Postgres and NATS JetStream (single node, one account) are in the compose file. Streams are named `<tenant>.steer` and `<tenant>.inbound`. The Kubernetes NATS shape is a 3-node cluster (headless service, port 6222, PVCs, durable streams).

To run Mix against compose Postgres/NATS only:

```sh
docker compose up postgres nats
mix setup
mix phx.server
```

## Sign-in

Two modes, same image. Neither is a build flag; both are environment.
[`diagrams/auth-runtime-modes.html`](diagrams/auth-runtime-modes.html) draws
both, plus the supervision path that keeps a failed provider from stopping the
node.

**Local** (`LOCAL_AUTH=true`, on by default) is a single bootstrap admin
account, with no identity provider. It is what `docker compose up` and the base
`k8s/` manifests use, so a cluster can come up and sign in before any IdP
exists.

The account is created on first boot and never rewritten afterwards, so a
restart cannot rotate a password out from under you.

| | Where the password comes from | How you read it |
| --- | --- | --- |
| Compose | generated | `docker compose logs portal` (printed once) |
| Kubernetes | `firstmate-admin` secret, created by `deploy/bootstrap-secrets.sh` | `kubectl -n firstmate get secret firstmate-admin -o jsonpath='{.data.password}' \| base64 -d` |

Set `BOOTSTRAP_ADMIN_EMAIL` and `BOOTSTRAP_ADMIN_PASSWORD` to choose them
yourself. A generated password is printed once and is not recoverable from the
database afterwards.

**OIDC** (`OIDC_ISSUER` plus `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`) adds a
"Continue with identity provider" button. Any OpenID Connect provider works —
Keycloak, Dex, Google, Okta, Entra — because every endpoint is read from the
issuer's discovery document. There is no per-vendor adapter to write. Put the
client credentials in a `firstmate-oidc` secret; `deploy/examples` has a worked
provider setup.

Anyone your provider authenticates may sign in. `ALLOWED_EMAIL_DOMAIN` is an
optional extra restriction for sites that want one; it is unset by default and
never gates the local account.

OIDC is optional and fails soft. An unset, misconfigured, or unreachable issuer
logs and leaves OIDC disabled: `/healthz`, the endpoint, and local sign-in stay
up, and the login page says the provider is unreachable rather than pretending
it is unconfigured. Missing OIDC settings and a missing OS CA bundle are both
survivable; neither takes the node down.

On an image with no CA bundle, point `OIDC_CACERTFILE` (or `SSL_CERT_FILE`) at a
PEM file. The portal falls back to the bundle it ships at `priv/ssl/cacert.pem`,
so outbound TLS works even on a scratch base image.

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

Site-specific hostnames, issuer URLs, allowlists, and ghcr namespaces live in:

- `.env` / `docker-compose.override.yml` (from the `.example` files)
- `deploy/examples/` notes
- Kubernetes secrets created by `deploy/bootstrap-secrets.sh`

They are not compiled-in defaults.

## Kubernetes

`k8s/` is a generic firstmate namespace: CNPG, 3-replica NATS JetStream, portal Deployment, HTTPRoute to `firstmate.example.com`. Overlay real hostnames and registry tags in your GitOps repo.

```sh
kubectl apply -k k8s
./deploy/bootstrap-secrets.sh
```

`fm-steer` is the HTTP inbox port (`put` / `next` / `ack` / `list`). It does not dial NATS. The Phoenix API is the only JetStream client. The on-disk firstmate inbox stays until dual-write is wired.
