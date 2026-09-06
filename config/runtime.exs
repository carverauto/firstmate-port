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

  config :firstmate_port, public_url: public_url

  # Behind a gateway the socket peer is the gateway, so without this every
  # client shares one rate-limit bucket. Set CLIENT_IP_HEADER to the header the
  # edge actually populates. See FirstmatePort.Security.ClientIP and
  # docs/security.md for the deployment matrix.
  config :firstmate_port, :client_ip,
    header: System.get_env("CLIENT_IP_HEADER"),
    trusted_hops: String.to_integer(System.get_env("CLIENT_IP_TRUSTED_HOPS") || "0")

  # Flip to "enforce" once the browser console is clean under report-only.
  config :firstmate_port, FirstmatePortWeb.Plugs.SecurityHeaders,
    csp_mode: if(System.get_env("CSP_MODE") == "enforce", do: :enforce, else: :report_only),
    csp_report_uri: System.get_env("CSP_REPORT_URI")

  # Who operates this instance, for the public /terms and /privacy pages.
  # Set LEGAL_CONTACT_EMAIL before pointing Discord's Developer Portal at them.
  config :firstmate_port, :legal,
    operator: System.get_env("LEGAL_OPERATOR"),
    contact_email: System.get_env("LEGAL_CONTACT_EMAIL"),
    governing_law: System.get_env("LEGAL_GOVERNING_LAW")

  config :firstmate_port, FirstmatePort.Auth.Guardian,
    issuer: "firstmate_port",
    secret_key: secret_key_base,
    ttl: {12, :hours}

  config :firstmate_port, FirstmatePort.NATS.Connection,
    enabled: System.get_env("NATS_ENABLED") in ~w(true 1),
    host: System.get_env("NATS_HOST") || "nats",
    port: String.to_integer(System.get_env("NATS_PORT") || "4222"),
    name: :firstmate_nats,
    token: System.get_env("NATS_TOKEN"),
    username: System.get_env("NATS_USER"),
    password: System.get_env("NATS_PASSWORD"),
    replicas: String.to_integer(System.get_env("NATS_REPLICAS") || "1")

  # Preserve boot compatibility through key derivation. Before changing keys,
  # follow docs/credentials.md to keep existing ciphertext readable.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      Base.encode64(:crypto.hash(:sha256, "firstmate-port cloak v1:" <> secret_key_base))

  config :firstmate_port, FirstmatePort.Vault,
    key: cloak_key,
    # Each key generation needs its own tag; see docs/credentials.md.
    tag: System.get_env("CLOAK_KEY_TAG") || "AES.GCM.V1",
    retired_keys:
      System.get_env("CLOAK_KEYS_RETIRED", "")
      |> String.split(",", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [tag, key] ->
            {String.trim(tag), String.trim(key)}

          _ ->
            raise "CLOAK_KEYS_RETIRED must be comma-separated tag=base64key pairs"
        end
      end)

  # Deployment switches and secret setup: docs/build-tracking.md.
  config :firstmate_port, :build_tracking,
    kubernetes_enabled: System.get_env("KUBERNETES_TRACKING_ENABLED") in ~w(true 1),
    docker_enabled: System.get_env("DOCKER_TRACKING_ENABLED") in ~w(true 1),
    buildbuddy_host: System.get_env("BUILDBUDDY_HOST"),
    buildbuddy_api_key:
      (case System.get_env("BUILDBUDDY_ORG_API_KEY_FILE") do
         nil -> System.get_env("BUILDBUDDY_ORG_API_KEY")
         path -> path |> File.read!() |> String.trim()
       end)

  config :firstmate_port, FirstmatePortWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :firstmate_port, FirstmatePortWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :firstmate_port, FirstmatePortWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :firstmate_port, FirstmatePort.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
