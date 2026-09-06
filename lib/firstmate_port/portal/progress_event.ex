defmodule FirstmatePort.Portal.ProgressEvent do
  @moduledoc """
  Append-only fleet-log events attached to a `FirstmatePort.Portal.ProgressItem`.

  The fleet log is a log, not a mutable record. Reaching complete, being merged,
  going back in progress, a reassignment, an extra contributor, an interruption:
  each one appends a row here. Nothing rewrites an earlier row. The resource
  therefore exposes only `:read` and `:append` — there is no update or destroy
  action to call, and `test/firstmate_port/portal/progress_event_test.exs` holds
  that line.

  Current status, current assignee, totals, and the charts are all *projections*
  of these rows; see `FirstmatePort.Portal.ProgressProjection`. Newest event wins
  for the single-value projections, and the details view lists every row.

  Unlike the mutable portal resources this one carries neither AshPaperTrail nor
  AshEvents: versioning an append-only table would only duplicate it.

  External producers (fm-steer and firstmate) POST events; the GitHub poll
  appends through `FirstmatePort.Portal.ProgressLog`. See
  `docs/progress.md` for the wire contract. They never replace firstmate's
  on-disk inbox/status files.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    # The primary read deliberately bounds history reads as well as relationships.
    primary_read_warning?: false,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "progress_events"
    repo FirstmatePort.Repo

    references do
      reference :item, on_delete: :delete, index?: true
    end
  end

  @types [:status, :assignment, :contribution, :interruption, :note, :subject]
  @statuses FirstmatePort.Portal.ProgressStatus.all()
  @roles [:implement, :review]

  @doc "Event types this log accepts."
  def types, do: @types

  @doc "The public statuses, straight from `FirstmatePort.Portal.ProgressStatus`."
  def statuses, do: @statuses

  @doc "Contribution roles: who implemented, who reviewed."
  def roles, do: @roles

  code_interface do
    define :list, action: :read
    define :append, action: :append
    define :list_for_item, action: :for_item, args: [:item_id]
  end

  actions do
    read :read do
      primary? true
      prepare build(limit: 100, sort: [occurred_at: :asc, inserted_at: :asc, id: :asc])
    end

    read :for_item do
      description "A bounded event page, oldest first; continue with offset and limit."
      argument :item_id, :string, allow_nil?: false
      filter expr(item_id == ^arg(:item_id))
      argument :limit, :integer, default: 100, allow_nil?: false
      argument :offset, :integer, default: 0, allow_nil?: false
      validate compare(:limit, greater_than: 0, less_than_or_equal_to: 100)
      validate compare(:offset, greater_than_or_equal_to: 0)
      prepare build(sort: [occurred_at: :asc, inserted_at: :asc, id: :asc])

      prepare fn query, _ ->
        query
        |> Ash.Query.limit(query.arguments.limit)
        |> Ash.Query.offset(query.arguments.offset)
      end
    end

    create :append do
      primary? true
      description "Appends one event. The only way to write this log."

      accept [
        :item_id,
        :type,
        :title,
        :kind,
        :status,
        :worker,
        :role,
        :runtime,
        :model,
        :effort,
        :duration_ms,
        :tokens,
        :interrupted,
        :detail,
        :occurred_at
      ]

      change FirstmatePort.Changes.AssignPublicId

      change fn changeset, _ctx ->
        case Ash.Changeset.get_attribute(changeset, :occurred_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :occurred_at, DateTime.utc_now())
          _ -> changeset
        end
      end

      validate FirstmatePort.Portal.Validations.ProgressEventPayload
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:append) do
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

    attribute :type, :atom do
      constraints one_of: @types
      allow_nil? false
      public? true
    end

    attribute :title, :string, public?: true

    attribute :kind, :atom,
      public?: true,
      constraints: [one_of: [:pr, :issue, :achievement, :note]]

    attribute :status, :atom do
      constraints one_of: @statuses
      public? true
      description "Set on :status events. One of the public statuses, nothing else."
    end

    attribute :worker, :string do
      default ""
      public? true
      description "The crewmate or human this event is about."
    end

    attribute :role, :atom do
      constraints one_of: @roles
      public? true
      description "Set on :contribution events so review work is called out as review."
    end

    attribute :runtime, :string do
      default ""
      public? true
      description "Agent runtime or tool, e.g. claude-code. Never guessed from a PR author."
    end

    attribute :model, :string do
      default ""
      public? true
    end

    attribute :effort, :string do
      default ""
      public? true
    end

    attribute :duration_ms, :integer do
      public? true
      constraints min: 0
    end

    attribute :tokens, :integer do
      public? true
      constraints min: 0
    end

    attribute :interrupted, :boolean do
      public? true
      description "nil means nobody reported either way, which the UI shows as unknown."
    end

    attribute :detail, :string do
      default ""
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :item, FirstmatePort.Portal.ProgressItem do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end
end
