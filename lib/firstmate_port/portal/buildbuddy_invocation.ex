defmodule FirstmatePort.Portal.BuildBuddyInvocation do
  @moduledoc """
  Opt-in BuildBuddy invocation records. Users record the invocations they
  care about; rows can be enriched through `FirstmatePort.BuildBuddy` when
  an org API key is configured.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "buildbuddy_invocations"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at])
    attributes_as_attributes([:tenant_slug])
  end

  events do
    event_log(FirstmatePort.Events.EventLog)
    only_actions([:record])
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
      argument :id, :string, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :record do
      primary? true

      accept [
        :invocation_id,
        :host,
        :status,
        :commit_sha,
        :branch,
        :repo_url,
        :buildbuddy_url,
        :pr_url,
        :outcome
      ]

      validate {FirstmatePort.Validations.TrackingEnabled, track: :buildbuddy}
      change FirstmatePort.Changes.AssignPublicId
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :buildbuddy_url, required?: false}
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :pr_url, required?: false}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:record) do
      authorize_if expr(^actor(:role) == :agent)
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 4, max_length: 64
    end

    attribute :invocation_id, :string do
      allow_nil? false
      public? true
    end

    attribute :host, :string do
      default ""
      public? true
    end

    attribute :status, :string do
      default ""
      public? true
    end

    attribute :commit_sha, :string do
      default ""
      public? true
    end

    attribute :branch, :string do
      default ""
      public? true
    end

    attribute :repo_url, :string do
      default ""
      public? true
    end

    attribute :buildbuddy_url, :string do
      default ""
      public? true
    end

    attribute :pr_url, :string do
      default ""
      public? true
    end

    attribute :outcome, :string do
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
    identity :unique_invocation, [:invocation_id]
  end
end
