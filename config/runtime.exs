import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/firstmate_port start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :firstmate_port, FirstmatePortWeb.Endpoint, server: true
end

# Authentication is configured the same way in every runtime, so a setting that
# works in compose works in Kubernetes. Test stays hermetic: it must not pick up
# an issuer from a developer's shell.
if config_env() != :test do
  # Runtime auth settings and compatibility names: docs/deploy.md, "Sign-in".
  local_auth? = System.get_env("LOCAL_AUTH") || System.get_env("DEV_AUTH")

  oidc_issuer = System.get_env("OIDC_ISSUER")
  oidc_discovery = System.get_env("OIDC_DISCOVERY_URL")

  # One source of truth for the callback URL. An explicit OIDC_REDIRECT_URI wins;
  # otherwise derive it from PUBLIC_URL, which is what a portal behind a
  # TLS-terminating proxy needs so the redirect matches what is registered at the
  # provider. With neither set, Ueberauth derives it from the request, which is
  # right for localhost.
  oidc_redirect_uri =
    case {System.get_env("OIDC_REDIRECT_URI"), System.get_env("PUBLIC_URL")} do
      {uri, _} when is_binary(uri) and uri != "" ->
        uri

      {_, public} when is_binary(public) and public != "" ->
        String.trim_trailing(public, "/") <> "/auth/oidc/callback"

      _ ->
        nil
    end

  config :firstmate_port,
    allowed_email_domain: System.get_env("ALLOWED_EMAIL_DOMAIN"),
    oidc_issuer: oidc_issuer,
    local_auth: local_auth? not in ~w(false 0),
    enable_saas: System.get_env("ENABLE_SAAS") in ~w(true 1)

  # Optional in every runtime. An unset, wrong, or unreachable issuer leaves the
  # portal serving local sign-in; it never stops the node.
  config :firstmate_port, FirstmatePort.Auth.OIDC,
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET"),
    issuer: oidc_issuer,
    discovery_url: oidc_discovery,
    redirect_uri: oidc_redirect_uri,
    scopes: ["openid", "email", "profile"]

  # Client credentials for the Ueberauth strategy, read at request time. The
  # issuer list stays empty on purpose; see config/config.exs.
  oidc_provider_opts =
    [
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET")
    ] ++ if(oidc_redirect_uri, do: [redirect_uri: oidc_redirect_uri], else: [])

  config :ueberauth_oidcc, issuers: [], providers: [oidc: oidc_provider_opts]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :firstmate_port, FirstmatePort.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: openssl rand -base64 48
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :firstmate_port, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  public_url = System.get_env("PUBLIC_URL") || "http://#{host}:#{port}"

