# Deploy

## Local

```sh
cp .env.example .env
# fill SECRET_KEY_BASE: mix phx.gen.secret
docker compose up --build
```

Open http://localhost:4000/login. With `DEV_AUTH=true`, sign in as `captain@localhost`.

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

## Images

Harbor is the internal registry. ghcr.io is a later public mirror the captain will set up. Do not invent a second forge.

```sh
docker build -t firstmate-port:local .
# Internal publish (example):
# docker tag firstmate-port:local registry.example.com/firstmate/firstmate-port:sha-$(git rev-parse --short HEAD)
# docker push registry.example.com/firstmate/firstmate-port:sha-$(git rev-parse --short HEAD)
./deploy/sign-and-push.sh sha256:<digest>
```

Site-specific hostnames, Authentik URLs, allowlists, and Harbor projects live in:

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
