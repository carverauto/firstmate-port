defmodule FirstmatePort.Accounts.User do
  @moduledoc """
  Portal actor. Humans sign in via OIDC or local auth; agents use a hashed API key.
  """

  import Ash.Expr
  require Ash.Query

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "users"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at, :hashed_api_key])
  end

  code_interface do
    define :get, action: :read, get_by: [:id]
    define :get_by_email, action: :by_email, args: [:email]
    define :upsert_oidc, action: :upsert_oidc
    define :bootstrap_agent, action: :bootstrap_agent
    define :authenticate_api_key, action: :authenticate_api_key, args: [:token]
  end

  actions do
    defaults [:read]

    read :by_email do
      get? true
      argument :email, :ci_string, allow_nil?: false
      filter expr(email == ^arg(:email))
    end

    create :upsert_oidc do
      upsert? true
      upsert_identity :unique_email
      accept [:email, :name, :tenant_slug]
      change set_attribute(:role, :human)
      change FirstmatePort.Accounts.User.AssignDefaultTenant
    end

    create :bootstrap_agent do
      upsert? true
      upsert_identity :unique_email
      accept [:email, :name, :hashed_api_key, :tenant_slug]
      change set_attribute(:role, :agent)
      change FirstmatePort.Accounts.User.AssignDefaultTenant
    end

    read :authenticate_api_key do
      get? true
      argument :token, :string, allow_nil?: false, sensitive?: true

      prepare fn query, _ ->
        hash = FirstmatePort.Accounts.User.hash_token(Ash.Query.get_argument(query, :token))
        Ash.Query.filter(query, expr(hashed_api_key == ^hash and role == :agent))
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action([:upsert_oidc, :bootstrap_agent, :authenticate_api_key, :by_email]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :role, :atom do
      constraints one_of: [:human, :agent]
      default :human
      allow_nil? false
      public? true
    end

    attribute :hashed_api_key, :string do
      sensitive? true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end

  def hash_token(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  def agent?(user), do: user.role == :agent
end
