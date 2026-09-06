# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Scheduler lives in this app (same role as serviceradar_core_elx).
config :ash_oban, oban_name: Oban

config :firstmate_port, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10, github: 2, fleet: 1],
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
    FirstmatePort.Credentials,
    FirstmatePort.Portal,
    FirstmatePort.Events,
    FirstmatePort.Fleet,
    FirstmatePort.Jobs
  ],
  public_url: "http://localhost:4000",
  # Unset means any account an identity provider vouches for may sign in. A
  # domain here is an extra restriction on top of the provider, not the login.
  allowed_email_domain: nil,
  oidc_issuer: nil,
  # Local sign-in is the default way in: a fresh portal must be signable-into
  # without an identity provider.
  local_auth: true,
  # Reserved compatibility switch; public images compile with this off.
  enable_saas: false,
  default_tenant_slug: "local",
  # The hostnames this deployment publishes its one interactions URL on (see
  # DISCORD_INTERACTIONS_HOSTS in .env.example). Empty means the portal and the
  # endpoint share one origin, which is the localhost default; the tenant an
  # interaction belongs to comes from the payload either way.
  discord_interactions_hosts: []

# Deliberately slow. Test config lowers it; nothing else should.
config :firstmate_port, FirstmatePort.Accounts.Password, iterations: 210_000

# Build tracking plates (Kubernetes rolls, Docker builds, BuildBuddy
# invocations) are opt-in. Absent config hides the plate, it never renders
# an empty state. See docs/build-tracking.md.
config :firstmate_port, :build_tracking,
  kubernetes_enabled: false,
  docker_enabled: false,
  buildbuddy_host: nil,
  buildbuddy_api_key: nil

config :firstmate_port, FirstmatePort.Auth.Guardian,
  issuer: "firstmate_port",
  secret_key: "dev-guardian-secret-change-in-runtime",
  ttl: {12, :hours}

# Session cookie salts. These are development defaults, shipped so the app runs
# out of the box, and they are NOT secrets — anyone reading this repo has them.
# `config/prod.exs` overrides all three from the environment. Confidentiality
# rests on SECRET_KEY_BASE, which is required from the environment at runtime.
config :firstmate_port, :session,
  signing_salt: "firstmate-port-dev-session-signing",
  encryption_salt: "firstmate-port-dev-session-encryption",
  secure: false

# Which request header carries the client address, and how many proxies sit in
# front. `nil` means trust nothing and use the socket peer, which is right for
# `mix phx.server` and Docker Compose. Behind a gateway, set it — otherwise every
# request shares one rate-limit bucket. See FirstmatePort.Security.ClientIP.
config :firstmate_port, :client_ip, header: nil, trusted_hops: 0

# Sign-in lockout: 10 failures for one account inside 15 minutes locks that
# account for 15 minutes, however many source addresses the failures came from.
config :firstmate_port, FirstmatePort.Security.Lockouts,
  threshold: 10,
  window_seconds: 900,
  lock_seconds: 900

# Per-bucket limits live in FirstmatePort.Security.RateLimiter as compiled-in
# defaults so a deployment that configures nothing is still limited. Override a
# single bucket here or in config/runtime.exs:
#
#     config :firstmate_port, FirstmatePort.Security.RateLimiter,
#       buckets: %{auth_local: [limit: 5, window_seconds: 60]}

# CSP starts in report-only so a policy mistake is a console warning rather than
# a blank portal. Flip to `:enforce` once the browser console is clean — the
# inline theme script is already nonced, so nothing should be reported.
config :firstmate_port, FirstmatePortWeb.Plugs.SecurityHeaders,
  csp_mode: :report_only,
  csp_report_uri: nil

# Operator identity on the public /terms and /privacy pages. Deployment
# identity, not product copy: see FirstmatePort.Legal.
config :firstmate_port, :legal,
  operator: nil,
  contact_email: nil,
  governing_law: nil

# OIDC is optional and vendor-neutral. Compiled defaults configure no issuer, so
# a fresh checkout and the public image run on local auth alone. Real values are
# read from the environment in config/runtime.exs; nothing here is baked into a
# release.
config :firstmate_port, FirstmatePort.Auth.OIDC,
  client_id: nil,
  client_secret: nil,
  issuer: nil,
  discovery_url: nil,
  redirect_uri: nil,
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

# Deliberately empty, in every environment. UeberauthOidcc.Application starts one
# permanent child per entry, and a provider that cannot load its configuration
# crashes there and terminates the node. FirstmatePort.Auth.OIDC.Supervisor owns
# the provider instead, as a temporary child.
config :ueberauth_oidcc, issuers: []

config :ueberauth, Ueberauth,
  providers: [
    oidc:
      {Ueberauth.Strategy.Oidcc,
       [
         # The name of the provider process, not a vendor.
         issuer: :firstmate_oidc,
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

# Keep secrets out of request and LiveView event logs. `value` is the parameter
# tenant credentials are submitted under; the rest are the usual suspects.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "value",
  "api_key",
  "public_key",
  "client_secret"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
