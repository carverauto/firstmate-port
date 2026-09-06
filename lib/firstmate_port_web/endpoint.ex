defmodule FirstmatePortWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :firstmate_port

  # The session cookie is signed *and* encrypted, so its contents are opaque to
  # anyone without SECRET_KEY_BASE rather than merely tamper-evident. Both salts
  # are compile-time values because Plug.Session options are baked into the
  # endpoint module; `config/prod.exs` reads them from the environment at
  # release-build time so an operator can rotate them to invalidate every live
  # session. See `docs/security.md` — turning encryption on signs everyone out
  # once, at the deploy that introduces it.
  #
  # `Secure` follows `SESSION_COOKIE_SECURE` (true in prod builds) so the cookie
  # never travels over plain HTTP; dev and test keep it false so sign-in works
  # against `http://localhost`.
  #
  # `SameSite=Lax` rather than `Strict`: the OIDC provider bounces the browser
  # back to `/auth/oidc/callback` as a top-level cross-site GET, and `Strict`
  # would withhold the cookie on exactly that navigation. `Lax` still withholds
  # it from cross-site subresources and POSTs, and `protect_from_forgery` covers
  # state-changing requests.
  #
  # `max_age` matches the 12h Guardian token TTL, so the cookie cannot outlive
  # the credential inside it.
  @session_options [
    store: :cookie,
    key: "_firstmate_port_key",
    same_site: "Lax",
    http_only: true,
    max_age: 12 * 60 * 60,
    signing_salt: Application.compile_env!(:firstmate_port, [:session, :signing_salt]),
    encryption_salt: Application.compile_env!(:firstmate_port, [:session, :encryption_salt]),
    secure: Application.compile_env(:firstmate_port, [:session, :secure], false)
  ]

  # First, ahead of sockets and static files: a hostname that exists only for
  # Discord interactions serves nothing but `POST /interactions`, whatever the
  # gateway in front of us was configured to forward.
  plug(FirstmatePortWeb.Plugs.DiscordHostGuard)

