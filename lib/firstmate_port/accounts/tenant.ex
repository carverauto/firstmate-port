defmodule FirstmatePort.Accounts.Tenant do
  @moduledoc "A tenant. Rows are attribute-scoped; JetStream streams are <slug>.steer and <slug>.inbound."

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
    define :set_embedding_model, action: :set_embedding_model
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
      accept [:slug, :name]
    end

    update :set_embedding_model do
      description """
      Chooses the embedding model for this tenant's fleet-log search, or clears
      it with an empty string. The API key is a credential slot, not an
      attribute here; see `FirstmatePort.Fleet.Embeddings`.
      """

      # The validation asks the provider library whether the spec names an
      # embedding model, which is not something Postgres can do in an UPDATE.
      require_atomic? false

      accept [:embedding_model]

      validate FirstmatePort.Fleet.Validations.EmbeddingModel
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:seed) do
      authorize_if always()
    end

    policy action(:set_embedding_model) do
      # Tenant settings are set by the people who own the tenant. Agent API keys
      # deliberately cannot change which provider the fleet log is sent to.
      authorize_if expr(^actor(:role) == :human and slug == ^actor(:tenant_slug))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :embedding_model, :string do
      default ""
      allow_nil? false
      public? true

      description """
      `provider:model` spec for fleet-log embeddings, empty to fall back to the
      deployment default. Not a secret: the key lives in the credential store.
      """

      constraints max_length: 200, allow_empty?: true
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
