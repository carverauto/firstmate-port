defmodule FirstmatePort.Auth.CliSession do
  @moduledoc """
  One `fm-steer` login: the record behind "which CLIs can act as me, and stop that one".

  A device-code grant hands out a JWT that is good for hours and lives in a file
  on whatever machine ran `fm-steer auth login`. Without a record of it there is
  nothing to show the captain and nothing to revoke, so every issued CLI token
  writes a row here keyed by its `jti`, and
  `FirstmatePort.Auth.Guardian.verify_claims/2` refuses any CLI token whose row
  is missing or revoked. Revocation therefore takes effect on the next request,
  not when the token would have expired.

  Sessions belong to the person who approved them. A captain sees and revokes
  their own; nothing here lets one member of a tenant end another's session.
  """

  import Ash.Expr
  require Ash.Query

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "cli_sessions"
    repo FirstmatePort.Repo
  end

  code_interface do
    define :mine, action: :mine
    define :open, action: :open
    define :get_by_jti, action: :by_jti, args: [:jti], not_found_error?: false
    define :seen, action: :seen
    define :revoke, action: :revoke
  end

  actions do
    defaults [:read]

    read :mine do
      description "The signed-in user's own sessions, newest first."
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_jti do
      description "Looked up on every request that carries a CLI token."
      get? true
      argument :jti, :string, allow_nil?: false
      filter expr(jti == ^arg(:jti))
    end

    create :open do
      primary? true
      accept [:jti, :user_id, :tenant_slug, :instance, :user_agent, :expires_at]
    end

    update :seen do
      description "Stamps last use, so a stale session is recognisable in the list."
      accept []
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    update :revoke do
      description "Ends the session. The token stops working on its next request."
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # `by_jti` and `seen` are the authentication path itself: they run before
    # there is an actor to authorize, so the app calls them with
    # `authorize?: false` and they carry no policy of their own.
    bypass action([:by_jti, :seen, :open]) do
      authorize_if always()
    end

    policy action_type([:read, :update]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :jti, :string do
      allow_nil? false
      description "The token's own id. Not a secret: it identifies the token without being one."
    end

    attribute :user_id, :uuid_v7 do
      allow_nil? false
      public? true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    attribute :instance, :string do
      default ""
      allow_nil? false
      public? true
      description "The server's configured public portal URL when the session was issued."
      constraints max_length: 500, allow_empty?: true
    end

    attribute :user_agent, :string do
      default ""
      allow_nil? false
      public? true
      description "What asked for the token, so an unfamiliar machine is visible."
      constraints max_length: 500, allow_empty?: true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_jti, [:jti]
  end

  @doc """
  Whether a CLI token's session is still good.

  Called on every request carrying one, so it does the cheap checks itself and
  only writes when the "last used" stamp has gone stale.
  """
  # Matches on the fields rather than the struct: Ash defines __struct__ too
  # late in the module body for %__MODULE__{} to expand here.
  def active?(jti) when is_binary(jti) do
    case get_by_jti(jti, authorize?: false) do
      {:ok, %{revoked_at: nil} = session} ->
        _ = touch(session)
        true

      _ ->
        false
    end
  end

  def active?(_), do: false

  @touch_after_seconds 60

  defp touch(%{last_used_at: last} = session) do
    if is_nil(last) or DateTime.diff(DateTime.utc_now(), last) >= @touch_after_seconds do
      seen(session, %{}, authorize?: false)
    else
      :ok
    end
  end
end
