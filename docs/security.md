# Public-edge security — operator notes

`firstmate.carverauto.dev` is on the public shared Envoy Gateway, so the portal
is reachable from the internet rather than only from the LAN. This page is what
an operator needs in order to run it there: what was added, what has to be set,
and what to do when it fires.

The design follows serviceradar's `docs/PLATFORM_SECURITY_HARDENING.md` and the
web-ng plugs it describes. Where the portal is smaller, it is smaller
deliberately — the differences are called out below rather than left as
surprises.

## Why the hostname is public

Discord's Developer Portal will not accept an application without a reachable
Interactions endpoint, Terms of Service URL and Privacy Policy URL. The
interactions endpoint has its own hostname
(`discord-firstmate.carverauto.dev`, path-only `/interactions`, owned by the
Discord lane). The two legal URLs have to be on the portal itself, because they
describe the portal. A LAN-only hostname cannot serve either.

| Hostname | Gateway section | Serves |
| --- | --- | --- |
| `firstmate.carverauto.dev` | `serviceradar-system/serviceradar-shared-gateway`, `https-carverauto` | the whole portal, including public `/terms` and `/privacy` |
| `discord-firstmate.carverauto.dev` | same Gateway, `https-carverauto` | `/interactions` only |

Both are Cloudflare-proxied. MCP and NATS gain no hostname of their own: `/mcp`
stays a path on the portal behind the agent token, and NATS stays inside the
cluster.

[`docs/diagrams/public-vs-discord-hostnames.html`](diagrams/public-vs-discord-hostnames.html)
draws the split, including which plugs each hostname's traffic passes through.

## What has to be set

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `CLIENT_IP_HEADER` | behind a proxy | unset | Header carrying the client address. Unset means use the socket peer. |
| `TRUST_FORWARDED_PROTO` | behind a TLS-terminating gateway | `false` | Set `true` only when the gateway overwrites `x-forwarded-proto` and is the only path to the app. Resolves HTTPS at the endpoint for HSTS. |
| `CLIENT_IP_TRUSTED_HOPS` | no | `0` | Proxies to skip when reading `x-forwarded-for`, counting from the right. |
| `LEGAL_CONTACT_EMAIL` | before Discord | unset | Contact on `/terms` and `/privacy`. |
| `LEGAL_OPERATOR` | no | generic wording | Who runs this instance. |
| `LEGAL_GOVERNING_LAW` | no | clause omitted | Governing law for the terms. |
| `CSP_MODE` | no | `report_only` | `enforce` turns the policy on. |
| `CSP_REPORT_URI` | no | unset | Where browsers post violation reports. |
| `SESSION_SIGNING_SALT` | no | stable default | Read at `mix release` time. Rotating signs everyone out. |
| `SESSION_ENCRYPTION_SALT` | no | stable default | Same. |
| `SESSION_COOKIE_SECURE` | no | `true` in prod | `false` only for staging genuinely on plain HTTP. |

### Getting `CLIENT_IP_HEADER` right matters more than it looks

Rate limiting and lockout key on the client address. Behind a proxy,
`conn.remote_ip` is the proxy, so leaving this unset in Kubernetes puts every
request on earth into one bucket — the limiter would then throttle everyone at
once, which is worse than not having it.

Trusting the wrong header is the opposite failure. `x-forwarded-for` is a list
each hop appends to, and a client can prepend entries to it, so reading it
left-to-right reads attacker input. `FirstmatePort.Security.ClientIP` reads it
right-to-left instead: hop 0 is the entry the closest proxy wrote, which is the
address it actually saw.

| Deployment | Setting |
| --- | --- |
| `mix phx.server`, Docker Compose | unset — nothing is in front |
| Gateway only | `x-forwarded-for`, hops `0` |
| Cloudflare → Gateway | `cf-connecting-ip` |
| Cloudflare → Gateway, XFF instead | `x-forwarded-for`, hops `1` |

Only name a single-value header such as `cf-connecting-ip` when that edge is
the *only* path to the app. If a client can reach the Gateway directly, it can
send that header itself.

## Rollout order

Each step below stands alone and can be reverted alone.

1. **Configure the gateway trust boundary and deploy with CSP in report-only.**
   Set `TRUST_FORWARDED_PROTO=true` behind the TLS-terminating gateway (already
   set in the Kubernetes manifests); leave it off for localhost and Compose.
   Verify HTTPS responses carry HSTS. CSP resource directives start report-only;
   framing and form-action restrictions remain enforced, and API CSP is always
   enforced. The one inline
   script in the app — the pre-paint theme switch in the root layout — already
   carries a per-request nonce, so a clean console here is the expected
   outcome, not a hope.
2. **Watch the sign-in paths.** `FirstmatePort.Security.RateLimiter` and
   `FirstmatePort.Security.Lockouts` start denying on the first deploy. Denials
   log at warning and emit telemetry:
   `[:firstmate_port, :security, :rate_limit, :denied]` and
   `[:firstmate_port, :security, :lockout, :triggered]`.
3. **Apply the edge policy.** `portal-rate-limit-policy.yaml` in the carverauto
   overlay adds the Envoy `BackendTrafficPolicy` limits. Same shape the shared
   Gateway already uses for other public hosts.
4. **Flip CSP to enforce** once the console has been clean for a few days:
   `CSP_MODE=enforce`. It is runtime config, so no rebuild.

The deploy that introduces session encryption signs every active session out
once. Say so in advance; subsequent deploys are seamless.

## Response headers

`put_secure_browser_headers` already sets `x-frame-options`,
`x-content-type-options`, `referrer-policy` and friends.
`FirstmatePortWeb.Plugs.SecurityHeaders` adds:

* `strict-transport-security` on HTTPS responses — two years,
  `includeSubDomains`, no `preload` (turn preload on only once the apex domain
  is actually enrolled; it is hard to undo).
* `permissions-policy` denying camera, microphone, geolocation, payment, USB,
  serial and the rest by default.
* A Content-Security-Policy chosen per pipeline:

| Pipeline | Policy |
| --- | --- |
| `:browser` | same-origin everything, inline script only via the request's nonce, websockets for LiveView |
| `:diagram` (`/d/:id`) | allows inline script and style, because a stored Archify artifact *is* an inline-script document; still forbids framing, plugins, form posts and off-origin loads |
| `:api`, `:cli_auth`, `:mcp`, `:discord_http` | `default-src 'none'` |

Every pipeline must select an explicit `:browser`, `:embed` or `:api` preset.
Browser and embed resource directives follow `CSP_MODE`; their framing,
object, base-uri and form-action baseline stays enforced in either mode.
The API preset is always enforced.

The `:diagram` exception is the interesting one. Stored diagram HTML is
attacker-influenced content served from the app's own origin, so the strict
policy would be the safer choice — and would also stop every diagram from
rendering, which is the product. The policy narrows what such a document can
reach instead: no framing, no plugins, no form submission, no cross-origin
fetch.

## Rate limiting

Two layers, on purpose:

* **Envoy, at the edge.** Per-source-address, survives an app restart, and
  stops floods before they reach Phoenix. Configured in the overlay.
* **Phoenix, per endpoint.** `FirstmatePort.Security.RateLimiter`, tighter and
  aware of which endpoint is being hit. Counters live in one node's ETS and are
  lost on restart.

Serviceradar's limiter spreads its counters across a Horde cluster; this one
does not, because the portal Deployment runs a single replica. Scale it past
one and each replica enforces its own budget, so the effective limit multiplies
by the replica count — the edge policy is what holds the line then.

Denied requests get `429` with `retry-after` and
`{"error": "rate_limited", "retry_after": N}`, or a `303` back to `/login` with
a flash for browsers. Each mounted plug explicitly selects JSON or HTML; the
request Accept header does not select the response. Every response carries `x-ratelimit-limit`,
`x-ratelimit-remaining` and `x-ratelimit-reset`.

One endpoint answers differently on purpose: `POST /api/cli/auth/token` returns
`{"error": "slow_down"}`, the RFC 8628 code that tells `fm-steer` to widen its
polling interval instead of failing the login.

Buckets and their defaults are compiled into
`FirstmatePort.Security.RateLimiter` so a deployment that configures nothing is
still limited. Override one without touching the rest:

```elixir
config :firstmate_port, FirstmatePort.Security.RateLimiter,
  buckets: %{auth_local: [limit: 5, window_seconds: 60]}
```

## Sign-in lockout

The rate limiter keys on the client address, so it does nothing about a spray
that spends one attempt per address against one account.
`FirstmatePort.Security.Lockouts` keys on the account instead: 10 failures
inside 15 minutes locks that account for 15 minutes, wherever they came from.

Both sign-in paths feed it. The local form counts failed email-and-password
attempts; successful sign-in clears that account’s failures. The OIDC
callback counts an identity the provider vouched for but the optional allowlist refused,
which is a real account being turned away rather than a typo.

An expired lockout resets the account's failure count. Without that, the
failures that caused the lock are still inside the counting window when it
lifts, and the first honest typo after serving the wait locks the account
again.

Locked local sign-in requests get a `303` to `/login` with `retry-after` and a
flash. To clear one early, restart the pod — state is in memory. That is the
tradeoff for having no lockout table, no migration and no audit UI to prune; if
the portal ever needs a real audit trail, this is the module to promote to an
Ash resource.

```elixir
config :firstmate_port, FirstmatePort.Security.Lockouts,
  threshold: 10, window_seconds: 900, lock_seconds: 900
```

## Session cookie

Signed *and* encrypted, `HttpOnly`, `SameSite=Lax`, `Secure` in prod builds, and
`max-age` of 12 hours to match the Guardian token TTL so the cookie cannot
outlive the credential inside it.

`SameSite=Lax` rather than `Strict` because the OIDC provider returns the
browser to `/auth/oidc/callback` as a top-level cross-site GET, and `Strict`
would withhold the cookie on exactly that navigation. `Lax` still withholds it
from cross-site subresources and POSTs; `protect_from_forgery` covers
state-changing requests.

## What is deliberately absent

* **No CSP report collector.** `CSP_REPORT_URI` points wherever you like; the
  app does not host one. A report endpoint is an unauthenticated public POST,
  and for a crew-sized deployment the browser console is enough for the
  report-only soak.
* **No security audit UI.** Denials and lockouts go to the log and to
  telemetry. Serviceradar's `Settings → Audit` screens have no counterpart
  here.
* **No upload guard.** The portal takes no file uploads.
