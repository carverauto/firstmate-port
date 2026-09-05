# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Scheduler lives in this app (same role as serviceradar_core_elx).
config :ash_oban, pro?: false, oban_name: Oban

config :firstmate_port, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10, github: 2],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  repo: FirstmatePort.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :firstmate_port,
  ecto_repos: [FirstmatePort.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    FirstmatePort.Accounts,
    FirstmatePort.Portal,
    FirstmatePort.Events,
    FirstmatePort.Jobs
  ],
  public_url: "http://localhost:4000",
  allowed_email_domain: "localhost",
  oidc_issuer: nil,
  dev_auth: false,
  default_tenant_slug: "local"

config :firstmate_port, FirstmatePort.Auth.Guardian,
  issuer: "firstmate_port",
  secret_key: "dev-guardian-secret-change-in-runtime",
  ttl: {12, :hours}

config :firstmate_port, FirstmatePortWeb.Auth.OIDCStrategy,
  client_id: System.get_env("OIDC_CLIENT_ID") || "firstmate-port",
  client_secret: System.get_env("OIDC_CLIENT_SECRET"),
  issuer: System.get_env("OIDC_ISSUER"),
  discovery_url: System.get_env("OIDC_DISCOVERY_URL"),
  redirect_uri: System.get_env("OIDC_REDIRECT_URI") || "http://localhost:4000/auth/oidc/callback",
  scopes: ["openid", "email", "profile"]

config :firstmate_port, FirstmatePort.NATS.Connection,
  enabled: false,
  host: "127.0.0.1",
  port: 4222,
  name: :firstmate_nats,
  token: nil,
  username: nil,
  password: nil,
  replicas: 1

config :firstmate_port, :discord_public_key, nil

config :ueberauth_oidcc, issuers: []

config :ueberauth, Ueberauth,
  providers: [
    oidc:
      {Ueberauth.Strategy.Oidcc,
       [
         issuer: :firstmate_authentik,
         client_id: {:system, "OIDC_CLIENT_ID"},
         client_secret: {:system, "OIDC_CLIENT_SECRET"},
         scopes: ["openid", "email", "profile"],
         callback_path: "/auth/oidc/callback",
         uid_field: "email",
         userinfo: false
       ]}
  ]

# Configures the endpoint
config :firstmate_port, FirstmatePortWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FirstmatePortWeb.ErrorHTML, json: FirstmatePortWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FirstmatePort.PubSub,
  live_view: [signing_salt: "Fns8NiXf"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :firstmate_port, FirstmatePort.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  firstmate_port: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  firstmate_port: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
