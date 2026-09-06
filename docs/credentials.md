# Tenant credentials

Every secret a tenant needs - the Discord interactions public key, a bot token, a
GitHub token, a provider API key - is typed into the portal by the people who own
that tenant. The portal encrypts it with [AshCloak](https://hexdocs.pm/ash_cloak)
and stores the ciphertext in the same shared Postgres (CNPG) every other portal
row lives in.

There is no `kubectl create secret firstmate-discord`, and no per-tenant secret of
any other kind. Kubernetes holds the vault key and deployment infrastructure
secrets, as listed below; tenant credentials stay in Postgres.

For the optional deployment-wide BuildBuddy key, see
[build tracking](build-tracking.md#buildbuddy-org-api-key).

## What the cluster still holds

| Secret | Why it is not a tenant credential |
| --- | --- |
| `firstmate-cloak` / `key` (`CLOAK_KEY`) | It is what encrypts tenant credentials; it cannot live inside them. |
| `firstmate-pg-app`, `firstmate-app`, `firstmate-nats`, `firstmate-agent` | Infrastructure the app needs before any tenant exists. |

`deploy/bootstrap-secrets.sh` creates `firstmate-cloak` using the same SHA-256
derivation as the running portal: `"firstmate-port cloak v1:" <> SECRET_KEY_BASE`.
It reads the existing `firstmate-app` secret and preserves an existing
`firstmate-cloak`. This keeps credentials written before bootstrap readable.

Back it up with the database. Losing the key means every stored credential has to
be entered again; there is no recovery path, by design.

### If `CLOAK_KEY` is not set

The portal still boots. It derives a key from `SECRET_KEY_BASE`, which every
deployment already has, so a cluster that has not run
`deploy/bootstrap-secrets.sh` rolls without anyone creating a secret first - the
manifest marks the `firstmate-cloak` reference optional for exactly this reason.

The catch is that stored credentials are then tied to `SECRET_KEY_BASE`:
rotating it without setting `CLOAK_KEY` first makes them unreadable. Set an
explicit `CLOAK_KEY` equal to the existing derived key (the bootstrap script
does this), and the two become independent. To replace it with a random key,
follow the tagged rotation procedure below; never replace a key under the same tag.

`config/dev.exs` and `config/test.exs` carry fixed, non-secret keys so the dev
and test databases hold real ciphertext without any setup. Docker Compose also
defaults to the development key. For a fresh production installation, generate
an explicit key with `openssl rand -base64 32` before storing credentials. For an
existing database, preserve its current key or follow the rotation procedure.

## Storing a credential in the UI

1. Sign in and open **Credentials** in the top nav (`/settings/credentials`).
2. Pick a slot - or *Something else* to name your own provider and key.
3. Paste the secret and save.

The page never shows a stored secret again. It shows the slot, the last four
characters (only for values of at least 12 characters), and the byte size, which
helps distinguish tokens and spot a truncated paste. A secret that went in wrong
is replaced with **Rotate**, not read back and edited.

## Storing a credential over the API

The endpoints live under `/api/credentials` and accept a bearer API key or
device-code JWT, so `fm-steer auth login` is enough to get a token. The tenant
comes from the signed-in user, never from the request.

```sh
# What slots the portal knows about
curl -H "Authorization: Bearer $TOKEN" https://$HOST/api/credentials/slots

# Create or rotate in one call
curl -X PUT -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"value":"'"$DISCORD_PUBLIC_KEY"'","description":"prod bot"}' \
  https://$HOST/api/credentials/discord/public_key

# List (metadata only - no response ever contains a secret)
curl -H "Authorization: Bearer $TOKEN" https://$HOST/api/credentials

# Edit the note beside a slot without touching the secret
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"description":"release bot"}' \
  https://$HOST/api/credentials/discord/public_key

# Remove
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  https://$HOST/api/credentials/discord/public_key
```

`POST /api/credentials` also creates, and fails if the slot is already filled.
A `PUT` without a `description` leaves the existing note alone, so rotating a
secret does not quietly wipe the note next to it.

Writes require a human credential. An agent API key can list its tenant's slots
but cannot create, rotate, or delete one.

## Slots

A slot is a `provider`/`key` pair. Both are lowercase slugs, and a tenant may
fill any pair it likes - that is how a new integration gets credentials without a
schema change. The ones the portal knows by name are in
`lib/firstmate_port/credentials/slots.ex`, which is also where the shape checks
live (a `discord`/`public_key` that is not 64 hex characters is refused at the
form, not at the next inbound interaction).

Two slots are consumed by an integration today:

- `discord`/`public_key` verifies inbound interactions (below).
- `embeddings`/`api_key` is the provider key for optional fleet-log semantic
  search. It is read server-side and passed per request, never written into
  application environment. See [fleet-search.md](fleet-search.md); the model it
  is used with is a tenant setting, not a secret, and is chosen on the same
  page.

The rest are storage only: saving a GitHub token does not configure the existing
`GITHUB_TOKEN`-based poller, and saving a bot token does not wire outbound Discord
calls. Portal sign-in remains configured from the deployment environment; it
does not read `oidc`/`client_secret`.

## Discord inbound

Discord posts interactions to `POST /interactions` on this Phoenix app - there is
no sidecar and no separate service. Discord sends no tenant context, so the
**signature must match exactly one tenant**: the request is verified against every
tenant's stored `discord`/`public_key`. Only a unique matching tenant receives
the payload on its `<tenant>.discord.inbound` subject. Zero matches or multiple
matching tenants return 401 without publishing. Tenants can store the same app
key, but interactions remain unauthorized until the ambiguity is removed.

All stored keys are considered, with no tenant cutoff. Keys are read fresh on
each interaction, so storing, rotating, or deleting a key takes effect
immediately, with no cache to invalidate and no restart.

To point a Discord app at a tenant:

1. Store that app's public key in the tenant's `discord`/`public_key` slot.
2. Set the app's interactions endpoint to `https://<discord host>/interactions`.
3. Discord's own PING verification will now pass against the stored key.

Environment `DISCORD_PUBLIC_KEY` values are not accepted. Enter the key through
the portal UI or API, including on a fresh install. Portal login and cluster
startup do not require a Discord credential.

## How the secret is protected

- **At rest.** AshCloak encrypts `value` into an `encrypted_value` column with
  AES-256-GCM. The plaintext column does not exist.
- **On the way out.** `value` is a private field, so no JSON API, MCP tool, or
  serializer can reach it, and `FirstmatePort.Credentials.DecryptGuard` refuses to
  decrypt for any query that did not ask for plaintext by name. Only
  `FirstmatePort.Credentials.secret/3` and `slot_across_tenants/2` do, and they
  are server-side. No HTTP response returns a secret.
- **Between tenants.** Rows are attribute-scoped by `tenant_slug`, and the read
  policy filters to the actor's own tenant even if a query is handed someone
  else's slug.
- **In the audit trail.** AshPaperTrail records which slot changed, under which
  action, by which user, and when - with the ciphertext column excluded from
  every version.
- **In logs.** Every decryption logs the tenant and slot. Never the value.

There is deliberately no AshAi tool for credentials: an MCP client must not be
able to enumerate a tenant's secrets.

## Rotating the vault key

`CLOAK_KEY` is a base64-encoded 32-byte key. `CLOAK_KEY_TAG` defaults to
`AES.GCM.V1`; `CLOAK_KEYS_RETIRED` accepts comma-separated `tag=base64key` pairs
for decryption only. The key can be replaced without re-encrypting the database
first. The supplied Kubernetes Deployment and Compose service wire only
`CLOAK_KEY`; add `CLOAK_KEY_TAG` and `CLOAK_KEYS_RETIRED` to the app environment
through your deployment overlay when rotating.

1. Move the current key to `CLOAK_KEYS_RETIRED` as `AES.GCM.V1=<old base64 key>`.
2. Put the new key in `CLOAK_KEY`, and give it a new tag: `CLOAK_KEY_TAG=AES.GCM.V2`.
3. Restart. Old rows still decrypt with the retired key; everything written from
   now on uses the new one.
4. Once every row has been rewritten - rotating each credential does this - drop
   the retired entry.

Every ciphertext carries the tag of the key that wrote it, and that tag is how a
stored value finds the key that can read it. A retired key that reused the active
tag would be shadowed by it, so the app refuses to boot in that case rather than
failing at the first read.
