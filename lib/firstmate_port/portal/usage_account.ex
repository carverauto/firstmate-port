defmodule FirstmatePort.Portal.UsageAccount do
  @moduledoc """
  Per-account token/billing counters. One row per provider account per
  tenant: allowance and window are configured, `used` is posted by agents
  and humans. Every post that carries `used` also appends a
  `FirstmatePort.Portal.UsageSnapshot`, which is what gives runway a burn
  rate. Remaining, status, and runway are computed in
  `FirstmatePort.Usage`, never stored.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "usage_accounts"
    repo FirstmatePort.Repo
  end

  code_interface do
    define :get, action: :by_id, args: [:id]
    define :list, action: :read
    define :record, action: :record
  end

  actions do
    defaults [:read]

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :record do
      primary? true
      upsert? true
      upsert_identity :unique_account

      accept [
        :provider,
        :label,
        :unit,
        :allowance,
        :used,
        :window,
        :reset_at,
        :spend_priority,
        :source,
        :notes
      ]

      change FirstmatePort.Changes.AppendUsageSnapshot
    end
  end

  policies do
    # Tenant-local bookkeeping: humans add accounts in the portal UI,
    # agents post usage. The tenant attribute is the wall.
    policy action_type([:read, :create]) do
      authorize_if actor_present()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :unit, :atom do
      constraints one_of: [:usd, :tokens, :credits]
      default :usd
      allow_nil? false
      public? true
    end

    attribute :allowance, :float do
      public? true
    end

    attribute :used, :float do
      default 0.0
      allow_nil? false
      public? true
    end

    attribute :window, :atom do
      constraints one_of: [:monthly, :weekly, :daily, :one_time]
      default :monthly
      allow_nil? false
      public? true
    end

    attribute :reset_at, :utc_datetime, public?: true

    attribute :spend_priority, :integer do
      default 100
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      constraints one_of: [:manual]
      default :manual
      allow_nil? false
      public? true
    end

    attribute :notes, :string do
      default ""
      public? true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_account, [:tenant_slug, :provider, :label]
  end
end
