defmodule FirstmatePort.Portal.DockerBuild do
  @moduledoc """
  Opt-in image build records. Users record the builds they care about;
  nothing is collected unless docker tracking is enabled.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "docker_builds"
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
        :repository,
        :tag,
        :status,
        :digest,
        :dockerfile,
        :context,
        :pr_url,
        :issue_url,
        :outcome
      ]

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

    attribute :repository, :string do
      allow_nil? false
      public? true
    end

    attribute :tag, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:started, :success, :failure]
      allow_nil? false
      public? true
    end

    attribute :digest, :string do
      default ""
      public? true
    end

    attribute :dockerfile, :string do
      default ""
      public? true
    end

    attribute :context, :string do
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
