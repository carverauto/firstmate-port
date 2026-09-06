defmodule FirstmatePort.Accounts.Tenant do
  @moduledoc """
  A tenant. Rows are attribute-scoped; JetStream streams are `<slug>_steer` and
  `<slug>_inbound`.

  A tenant may also claim a Discord application. That claim is what lets one
  interactions URL serve every tenant: Discord names the application it is
  calling for in the interaction payload, and `discord_application_id` says who
  that application belongs to. It is an identifier, not a secret - Discord puts
  it in every payload and the developer portal shows it in the clear - so it
  lives here beside the slug rather than in the encrypted credential store. The
  key that actually authenticates the request stays in
  `FirstmatePort.Credentials`.

  The claim is unique across tenants, so one Discord application can never be
  routed to two tenants.
  """

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

    define :get_by_discord_application_id,
      action: :by_discord_application_id,
      args: [:application_id]

    define :claim_discord_application, action: :claim_discord_application
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

    read :by_discord_application_id do
      description "The tenant that claimed a Discord application, if any."
      get? true
      argument :application_id, :string, allow_nil?: false
      filter expr(discord_application_id == ^arg(:application_id))
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

      # Provider availability is checked in Elixir; the validation cannot run
      # inside a Postgres UPDATE. Exact model validation stays with the provider.
      require_atomic? false

      accept [:embedding_model]

      validate FirstmatePort.Fleet.Validations.EmbeddingModel
    end

    update :claim_discord_application do
      description """
      Claims - or with a blank value releases - the Discord application whose
      interactions this tenant answers for.

      Nothing secret changes here, so no rotation semantics and no ciphertext:
      the claim only decides which tenant's stored public key an interaction is
      checked against.
      """

      accept [:discord_application_id]
      require_atomic? false

      change fn changeset, context ->
        Ash.Changeset.before_action(changeset, &refuse_unavailable_claim(&1, context.actor))
      end
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

    # Claiming a Discord application decides whose key verifies that
    # application's interactions, so only the people who own the tenant may do
    # it. Agent API keys, like everywhere else credentials are concerned,
    # cannot.
    policy action(:claim_discord_application) do
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
      `provider:model` spec for fleet-log embeddings, empty to disable
      embeddings. Not a secret: the key lives in the credential store.
      """

      constraints max_length: 200, allow_empty?: true
    end

    attribute :discord_application_id, :string do
      public? true

      description """
      Snowflake of the Discord application this tenant answers interactions
      for. Public routing data, never a secret.
      """

      constraints match: ~r/^[0-9]{1,32}$/
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]

    # One Discord application belongs to one tenant. Without this a tenant could
    # claim another's application and quietly take over the routing for it.
    identity :unique_discord_application_id, [:discord_application_id],
      nils_distinct?: true,
      message: "Discord application claim is not permitted"
  end

  defp refuse_unavailable_claim(changeset, actor) do
    application_id = Ash.Changeset.get_attribute(changeset, :discord_application_id)
    default = FirstmatePort.Tenancy.default_slug()

    if is_nil(application_id) do
      changeset
    else
      with {:ok, holder} <-
             get_by_discord_application_id(application_id,
               authorize?: false,
               not_found_error?: false
             ),
           true <- is_nil(holder) or holder.id == changeset.data.id,
           true <-
             changeset.data.slug == default or
               match?(%{role: :human, tenant_slug: ^default}, actor) or
               fallback_empty?(default) do
        changeset
      else
        _ ->
          Ash.Changeset.add_error(changeset,
            field: :discord_application_id,
            message: "Discord application claim is not permitted"
          )
      end
    end
  end

  defp fallback_empty?(default) do
    FirstmatePort.Credentials.Credential.get_slot("discord", "public_key",
      tenant: default,
      authorize?: false
    ) == {:ok, nil}
  end
end
