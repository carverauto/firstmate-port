defmodule FirstmatePort.Portal.UsageSnapshot do
  @moduledoc """
  Periodic `used` samples per usage account. The burn rate across the
  current billing window drives the runway estimate in
  `FirstmatePort.Usage`. One is appended for every posted reading that
  carries `used`. `by_account` returns the most recent samples only:
  runway never needs history from a spent window.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "usage_snapshots"
    repo FirstmatePort.Repo

    custom_indexes do
      index [:tenant_slug, :usage_account_id, :inserted_at]
    end
  end

  code_interface do
    define :list, action: :read
    define :for_account, action: :by_account, args: [:usage_account_id]
    define :record, action: :record
  end

  actions do
    defaults [:read]

    read :by_account do
      argument :usage_account_id, :uuid, allow_nil?: false
      prepare build(sort: [inserted_at: :desc], limit: 60)
      filter expr(usage_account_id == ^arg(:usage_account_id))
    end

    create :record do
      primary? true
      accept [:usage_account_id, :used, :source]
    end
  end

  policies do
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

    attribute :usage_account_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :used, :float do
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      constraints one_of: [:manual]
      default :manual
      allow_nil? false
      public? true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end
end
