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

The same page carries **Discord application**, which is not a secret and is
stored in the clear; see "Discord inbound" below.

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

`discord`/`public_key`, `embeddings`/`api_key`, and the two GitHub slots are consumed by integrations.
The rest are storage only: saving a bot token does not wire outbound Discord
calls, and portal sign-in remains configured from the deployment environment -
it does not read `oidc`/`client_secret`.

- `embeddings`/`api_key` is the provider key for optional fleet-log semantic
  search. It is read server-side and passed per request, never written into
  application environment. See [fleet-search.md](fleet-search.md); the model it
  is used with is a tenant setting, not a secret, and is chosen on the same
  page.

### GitHub

The scheduled poll visits every tenant with a tenant-scoped agent, taking the
first 50 open PRs and first 50 open issues for its organisation. A missing or
blank token or organisation skips that tenant. It reads two slots:

| Slot | What it is |
| --- | --- |
| `github`/`token` | The PAT it authenticates with |
| `github`/`org` | The organisation it searches for open PRs and issues |

Paste them at `/settings/credentials` and the poll picks them up on its next run
- no redeploy, and no GitHub token in a cluster secret. A fine-grained PAT needs
**Checks: Read** alongside read access to the repositories you want on the Fleet
log, because the poll reports each PR's check status; a classic token needs
`repo`.

`GITHUB_TOKEN` and `GITHUB_ORG` still work and are the fallback for a tenant
that has not filled the slots. A stored slot always wins over the environment,
so pasting a token in the portal is enough to take over from a deployment that
was configured the old way.

The Discord application id is public routing data, not a credential slot. It
lives on the tenant and is set from the same screen.

## Discord inbound

Discord posts interactions to `POST /interactions` on this Phoenix app - there is
no sidecar and no separate service. One URL serves every tenant: an operator sets
a single **Interactions Endpoint URL** in Discord and never has to create a
Discord application, a hostname, or a certificate per tenant.

Discord names the application it is calling for in the payload, so
**`application_id` carries the tenant**. A tenant claims its application on
`/settings/credentials`, and interactions for that application are verified with
that tenant's stored `discord`/`public_key` and no one else's.

| Payload `application_id` | Tenant |
| --- | --- |
| claimed by a tenant | that tenant |
| anything else | the default tenant |

Reading the claim out of a payload that has not been verified yet is safe
because the claim is a selector, not a credential: it decides *which* key the
signature is checked against, never *whether* a signature is needed. Naming
another tenant's application only means the request is measured against that
tenant's public key, which nothing but that tenant's own Discord application can
satisfy. A claim is unique across tenants, so one application can never be
routed to two of them.

"Anything else" is the whole of the fallback, and it is deliberately total: no
shape of payload resolves to no tenant, because resolving to no tenant would be
a path that reached a decision without a signature. Falling back to the default
tenant is not a weaker check, only a different key - the only interaction it can
authenticate is one signed by the default tenant's own application. It is also
what makes a fresh install work with nothing stored but a public key.

An application no tenant answers for and a signature no key verifies return the
same bare `401 unauthorized`, so the endpoint cannot be used to find out which
tenants or applications exist. Two tenants may hold the same Discord app key
without either speaking for the other - the claim, not the key, decides.

Keys are read fresh on each interaction, so storing, rotating, or deleting one
takes effect immediately, with no cache to invalidate and no restart. A
verified interaction is published on that tenant's `<tenant>.discord.inbound`
subject.

Beyond the signature, an interaction must also arrive with a timestamp within
300 seconds of now, and a body no larger than 64
KB. The body cap is applied while the request is being read, so an oversized
payload is never buffered or verified; it gets a 413.

Environment `DISCORD_PUBLIC_KEY` values are not accepted. Enter the key through
the portal UI or API, including on a fresh install. Portal login and cluster
startup do not require a Discord credential.

### Setting the interactions URL

Once per deployment, in the
[Discord developer portal](https://discord.com/developers/applications):

1. Store the application's public key in the tenant's `discord`/`public_key`
   slot on `/settings/credentials`. It is on the application's **General
   Information** page, as **Public Key**.
2. Optionally paste the application id from the same page into **Discord
   application** on that screen. Do it when more than one tenant answers
   interactions here, or to stop answering for anything else. A claim requires
   a human belonging to that tenant. An application already claimed by another
   tenant cannot be claimed. Once the default tenant stores its public key,
   other tenants cannot make new claims through their own accounts, protecting
   the default tenant's unclaimed-application fallback.
3. Set **Interactions Endpoint URL** to the URL the portal shows on
   `/settings/credentials` - `https://<interactions hostname>/interactions`.
   Discord also requires a **Terms of Service URL** and a **Privacy Policy URL**;
   point them at the deployment's own public terms and privacy pages.
4. Saving sends a signed PING from Discord. It answers PONG once the key is
   stored, and Discord refuses to save the URL until it does.

Order matters: step 1 before step 3. Discord validates the URL as part of saving
it, and an endpoint with no key stored answers 401 to the validating PING -
which Discord reports as an endpoint that could not be verified.

The key never leaves the portal: it is not a Kubernetes secret, not an
environment variable, and never appears in a chat message or an HTTP response.

### Publishing the interactions hostname

The interactions hostname is the only thing this deployment exposes publicly,
and it exposes exactly one path. `deploy/examples/carverauto/discord-httproute.yaml`
is a working example: an `Exact` `/interactions` match on the public gateway,
and nothing else. The portal UI, `/mcp`, `/api`, and NATS are not routed there,
and `FirstmatePortWeb.Plugs.DiscordHostGuard` answers 404 for any other path on
it even if a route is later widened.

Set the hostname in `DISCORD_INTERACTIONS_HOST`. That tells the app
which name is exposed; it does not route anything. Leave it
unset in development, where the portal and the endpoint share one origin.

If the hostname is behind Cloudflare, Cloudflare must reach the origin over TLS:
set SSL/TLS to **Full (strict)**, or add a Configuration Rule setting `ssl` to
`strict` for the interactions hostname alone when the zone default has to stay
as it is. Two failures follow from getting this wrong, and both look like an
endpoint that is simply "not live":

- **Flexible** makes Cloudflare fetch the origin over plain HTTP. Any
  origin-side HTTP-to-HTTPS redirect then becomes an endless loop - the 301
  travels back to the browser, the browser asks Cloudflare again - and Discord
  only ever sees a redirect, never a PONG. This is why the example manifest has
  no HTTP redirect route for the Discord hostname.
- Plain HTTP between Cloudflare and the origin also puts the interaction token
  in the payload on the wire in the clear. The Ed25519 signature protects
  authenticity, not confidentiality.

Verify from outside the cluster before pointing Discord at it. An unsigned POST
must answer `401` promptly:

```sh
curl -i -X POST -H 'content-type: application/json' -d '{"type":1}' \
  https://discord.example.com/interactions
```

A timeout means the request never reached the app; a `301` means the redirect
loop above; portal HTML means the hostname is routing more than `/interactions`.

## How the secret is protected

- **At rest.** AshCloak encrypts `value` into an `encrypted_value` column with
  AES-256-GCM. The plaintext column does not exist.
- **On the way out.** `value` is a private field, so no JSON API, MCP tool, or
  serializer can reach it, and `FirstmatePort.Credentials.DecryptGuard` refuses to
  decrypt for any query that did not ask for plaintext by name. Only
  `FirstmatePort.Credentials.secret/3` does, and it is server-side and always
  names the single tenant it is reading for. No HTTP response returns a secret.
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
