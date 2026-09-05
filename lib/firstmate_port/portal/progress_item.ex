defmodule FirstmatePort.Portal.ProgressItem do
  @moduledoc "PRs, closed issues, achievements, and notes. GitHub URLs are stored as copied."

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "progress_items"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at])
  end

  events do
    event_log(FirstmatePort.Events.EventLog)
    only_actions([:record, :touch])
  end

  code_interface do
    define :list, action: :read
    define :record, action: :record
    define :touch, action: :touch
    define :get_by_url, action: :by_url, args: [:url]
  end

  actions do
    defaults [:read]

    read :by_url do
      get? true
      argument :url, :string, allow_nil?: false
      filter expr(url == ^arg(:url))
    end

    create :record do
      primary? true
      accept [:kind, :title, :url, :body]
      change FirstmatePort.Changes.AssignPublicId
      change FirstmatePort.Changes.NormalizeProgressUrl
      change {FirstmatePort.Changes.FanoutDiscord, kind: :progress}
    end

    update :touch do
      accept [:kind, :title]
      change {FirstmatePort.Changes.FanoutDiscord, kind: :progress}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action([:record, :touch]) do
      authorize_if expr(^actor(:role) == :agent)
    end
  end

  multitenancy do
    strategy :context
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 4, max_length: 64
    end

    attribute :kind, :atom do
      constraints one_of: [:pr, :issue, :achievement, :note]
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      default ""
      public? true
    end

    attribute :body, :string do
      default ""
      public? true
    end

    timestamps()
  end
end
