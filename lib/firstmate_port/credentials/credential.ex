defmodule FirstmatePort.Credentials.Credential do
  @moduledoc """
  One secret a tenant typed into the portal, encrypted at rest with `AshCloak`.

  A credential is addressed by a `provider`/`key` slot - `discord`/`public_key`,
  `github`/`token`, or anything else a tenant needs - and is unique per tenant.
  Rows are attribute-scoped by `tenant_slug`, so the store is the same shared
  CNPG database every other portal resource uses.

  The plaintext leaves the database in exactly one place: `FirstmatePort.Credentials`
  reading it for the app itself. Both `value` and its `encrypted_value` column are
  private, so no JSON API, MCP tool, or serializer can reach them, and
  `FirstmatePort.Credentials.DecryptGuard` refuses to decrypt for a query that did
  not ask for it by name. No UI or API path reads a secret back - not even for the
  tenant that wrote it. The portal shows `hint` and `value_bytes` instead, and
  replacing a secret is a rotation rather than an edit.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Credentials,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshPaperTrail.Resource]

  postgres do
    table "tenant_credentials"
    repo FirstmatePort.Repo
  end

  cloak do
    vault(FirstmatePort.Vault)
    attributes [:value]
    on_decrypt({FirstmatePort.Credentials.DecryptGuard, :approve, []})
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    # Credentials really are deleted, so versions must not hold a foreign key to
    # the row they outlive.
    reference_source?(false)
    # Versions are the audit trail for who rotated what and when. They must never
    # carry the secret, so the ciphertext column is excluded from every version.
    ignore_attributes([:inserted_at, :updated_at, :encrypted_value])
    attributes_as_attributes([:tenant_slug])

    # Who rotated it, not just what changed. Nullable so background and seed
    # writes that run without an actor still record a version.
    belongs_to_actor(:user, FirstmatePort.Accounts.User,
      domain: FirstmatePort.Accounts,
      allow_nil?: true,
      attribute_type: :uuid_v7
    )
  end

  code_interface do
    define :list, action: :read
    define :get_slot, action: :by_slot, args: [:provider, :key], not_found_error?: false
    define :create, action: :create
    define :rotate, action: :rotate
    define :update_note, action: :update_details
    define :destroy, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :by_slot do
      get? true
      argument :provider, :string, allow_nil?: false
      argument :key, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider) and key == ^arg(:key))
    end

    create :create do
      primary? true
      # AshCloak rewrites :value out of `accept` into an encrypted argument.
      accept [:provider, :key, :description, :value]

      change FirstmatePort.Credentials.Changes.PrepareSecret
      validate FirstmatePort.Credentials.Validations.SlotValue
    end

    update :rotate do
      description """
      Replaces the secret in an existing slot and stamps `rotated_at`.

      The note travels with it so a single `PUT` can set both, and is left alone
      when the caller does not send one.
      """

      require_atomic? false
      accept [:value, :description]

      change {FirstmatePort.Credentials.Changes.PrepareSecret, rotation?: true}
      validate FirstmatePort.Credentials.Validations.SlotValue
    end

    update :update_details do
      description "Edits the note beside a slot. Never touches the secret."
      accept [:description]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(tenant_slug == ^actor(:tenant_slug))
    end

    policy action_type([:create, :update, :destroy]) do
      # Credentials are entered by the people who own the tenant. Agent API keys
      # deliberately cannot write them.
      authorize_if expr(^actor(:role) == :human and tenant_slug == ^actor(:tenant_slug))
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
    # Every credential read must name its tenant; inbound selection belongs to
    # FirstmatePort.Credentials.Discord, before this resource is read.
    global? false
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      description "Integration the secret belongs to, e.g. `discord` or `github`."
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9_-]*$/
    end

    attribute :key, :string do
      allow_nil? false
      public? true
      description "Slot within the provider, e.g. `public_key` or `bot_token`."
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9_-]*$/
    end

    attribute :value, :string do
      allow_nil? false
      sensitive? true
      public? false
      description "The secret. Encrypted by AshCloak; never read back over HTTP."
      constraints min_length: 1, max_length: 8192
    end

    attribute :description, :string do
      default ""
      allow_nil? false
      public? true
      # Ash casts "" to nil unless empty strings are allowed, and an empty note
      # is the normal case.
      constraints max_length: 500, allow_empty?: true
    end

    attribute :hint, :string do
      default ""
      allow_nil? false
      public? true
      description "Last four characters of the secret, for recognising it in a list."
      constraints max_length: 4, allow_empty?: true, trim?: false
    end

    attribute :value_bytes, :integer do
      default 0
      allow_nil? false
      public? true
      description "Byte size of the stored secret, so a truncated paste is visible."
    end

    attribute :rotated_at, :utc_datetime_usec do
      public? true
      description "When the secret was last replaced. Nil until the first rotation."
    end

    timestamps()
  end

  identities do
    identity :unique_slot, [:tenant_slug, :provider, :key]
  end
end
