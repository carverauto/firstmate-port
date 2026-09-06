defmodule FirstmatePort.Portal.Roll do
  @moduledoc """
  Kubernetes cluster image build and helm roll events. Recording is
  opt-in; see `FirstmatePort.BuildTracking`.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "rolls"
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
        :cluster,
        :namespace,
        :status,
        :image_tag,
        :rebuilt,
        :copied,
        :helm_revision,
        :pr_url,
        :issue_url,
        :outcome
      ]

      validate {FirstmatePort.Validations.TrackingEnabled, track: :kubernetes}
      change FirstmatePort.Changes.AssignPublicId
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :pr_url, required?: false}
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :issue_url, required?: false}
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

    attribute :cluster, :string do
      allow_nil? false
      public? true
    end

    attribute :namespace, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:started, :success, :failure]
      allow_nil? false
      public? true
    end

    attribute :image_tag, :string do
      allow_nil? false
      public? true
    end

    attribute :rebuilt, {:array, :string} do
      default []
      public? true
    end

    attribute :copied, {:array, :string} do
      default []
      public? true
    end

    attribute :helm_revision, :string do
      default ""
      public? true
    end

    attribute :pr_url, :string do
      default ""
      public? true
    end

    attribute :issue_url, :string do
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
end
