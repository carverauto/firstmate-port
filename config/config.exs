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
  # Seam, not a feature. Public images are OSS and compile with this off; the
  # SaaS lane owns sign-up, tenant provisioning, and billing in its own repo.
  # Tenancy is already attribute-based, so nothing here needs rewriting later.
  enable_saas: false,
