defmodule FirstmatePort.Accounts.Tenant do
  @moduledoc "A tenant owns one Postgres schema and one NATS JetStream account."

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tenants"
    repo FirstmatePort.Repo
  end

  code_interface do
    define :get, action: :read, get_by: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :seed, action: :seed
    define :list, action: :read
  end

  actions do
    defaults [:read]

    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
    end

    create :seed do
      upsert? true
      upsert_identity :unique_slug
      accept [:slug, :name, :nats_account, :nats_user, :nats_password]
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :nats_account, :string do
      allow_nil? false
      public? true
    end

    attribute :nats_user, :string do
      allow_nil? false
    end

    attribute :nats_password, :string do
      sensitive? true
      allow_nil? false
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
