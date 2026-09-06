defmodule FirstmatePort.Portal.BuildEvent do
  @moduledoc """
  Append-only build and deployment events posted by the crew.

  One row per report: `fm-steer build start` writes a `:started` event and
  `fm-steer build finish` writes a terminal one, both carrying the same
  `run_id`. Nothing rewrites an earlier row, so the log stays an audit trail;
  a single UI row is a projection over a run's events (see
  `FirstmatePort.BuildEvents`).

  `kind` names the build or deploy system (`k8s`, `docker`, `bazel`, ...) so
  one resource covers every system instead of one resource per system.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "build_events"
    repo FirstmatePort.Repo

    custom_indexes do
      # Every read is scoped to a tenant and either folds one run
      # (`:for_run`, `:latest_for_run`) or walks the log newest first.
      index [:tenant_slug, :run_id, :inserted_at]
    end
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
    define :for_run, action: :for_run, args: [:run_id]
    define :record, action: :record
  end

  actions do
    defaults [:read]

    read :by_id do
      get? true
      argument :id, :string, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :for_run do
      argument :run_id, :string, allow_nil?: false
      filter expr(run_id == ^arg(:run_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :latest_for_run do
      argument :run_id, :string, allow_nil?: false
      filter expr(run_id == ^arg(:run_id))
      prepare build(sort: [inserted_at: :desc], limit: 1)
    end

    create :record do
      primary? true

      accept [
        :run_id,
        :kind,
        :target,
        :status,
        :agent_id,
        :model,
        :effort,
        :tokens,
        :started_at,
        :finished_at,
        :image,
        :image_tag,
        :cluster,
        :namespace,
        :outcome
      ]

      change FirstmatePort.Changes.AssignPublicId
      change FirstmatePort.Changes.InheritBuildRun
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

    attribute :run_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 32
    end

    attribute :target, :string do
      default ""
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:started, :success, :failure, :cancelled]
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :model, :string do
      default ""
      public? true
    end

    attribute :effort, :string do
      default ""
      public? true
    end

    attribute :tokens, :integer do
      default 0
      public? true
      constraints min: 0
    end

    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    attribute :image, :string do
      default ""
      public? true
    end

    attribute :image_tag, :string do
      default ""
      public? true
    end

    attribute :cluster, :string do
      default ""
      public? true
    end

    attribute :namespace, :string do
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
