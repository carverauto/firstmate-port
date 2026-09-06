defmodule FirstmatePort.Portal.ProgressItem do
  @moduledoc """
  The subject rows of the fleet log: PRs, issues, achievements, and notes.
  GitHub URLs are stored as copied.

  This row is identity, not history. Status, assignment, contributions,
  duration, tokens, and interruptions all live in the append-only
  `FirstmatePort.Portal.ProgressEvent` log hanging off `:events`, and the UI
  reads them through `FirstmatePort.Portal.ProgressProjection`. Nothing rewrites
  an event; a change appends one.

  Progress is **crew work**, not a mirror of a GitHub organisation: the PRs,
  issues, and tasks this fleet actually worked, reviewed, or closed. `:record`
  therefore requires a `:worker`, which opens the log with an `:assignment`
  event. `FirstmatePort.Jobs.GitHubPoll` only enriches rows that already exist —
  it links them and moves their status when a PR merges or an issue closes. It
  never creates one. See `docs/progress.md`.
  """

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
    identity_wheres_to_sql unique_url: "url <> ''"
  end

  resource do
    base_filter expr(exists(events, type == :assignment))
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
    only_actions([:record, :touch])
  end

  @preview_size 10
  @page_size 20
  @max_page_size 100
  @stats_cap 1000

  @doc """
  Rows the home dashboard previews before handing off to /progress.

  Smaller than a `/progress` page on purpose: the home fleet log is a glance,
  not an archive.
  """
  def preview_size, do: @preview_size

  @doc "Rows per page on /progress."
  def page_size, do: @page_size

  @doc "Hard ceiling on a single list-API window."
  def max_page_size, do: @max_page_size

  @doc """
  Hard ceiling on how many items the /progress charts aggregate over, so a chart
  can never become an unbounded table scan.
  """
  def stats_cap, do: @stats_cap

  code_interface do
    define :list, action: :read
    define :record, action: :record
    define :touch, action: :touch
    define :get_by_url, action: :by_url, args: [:url]
    define :get_by_id, action: :read, get_by: [:id]
    define :list_recent, action: :recent
    define :list_paged, action: :paged, args: [:limit, :offset]
    define :list_for_stats, action: :for_stats
  end

  actions do
    defaults [:read]

    read :by_url do
      get? true
      argument :url, :string, allow_nil?: false
      filter expr(url == ^arg(:url))
    end

    read :recent do
      description "Newest progress items first, capped for the fleet-log preview."
      prepare build(sort: [inserted_at: :desc, id: :desc], limit: @preview_size)
    end

    read :paged do
      description "Newest progress items first with server-side limit+offset pagination."

      argument :limit, :integer, allow_nil?: false, default: @page_size
      argument :offset, :integer, allow_nil?: false, default: 0

      validate compare(:limit, greater_than: 0, less_than_or_equal_to: @max_page_size)
      validate compare(:offset, greater_than_or_equal_to: 0)

      prepare build(sort: [inserted_at: :desc, id: :desc])

      prepare fn query, _context ->
        query
        |> Ash.Query.limit(query.arguments[:limit] || @page_size)
        |> Ash.Query.offset(query.arguments[:offset] || 0)
      end
    end

    read :for_stats do
      description "Newest items the /progress charts aggregate over, hard-capped."
      prepare build(sort: [inserted_at: :desc, id: :desc], limit: @stats_cap)
    end

    create :record do
      primary? true
      description "Opens a fleet-log row for work a crew member is doing."
      accept [:kind, :title, :url, :body]

      argument :worker, :string do
        allow_nil? false

        description """
        The crew member whose work this is. Required: Progress tracks work this
        fleet did, so a row cannot exist without naming who is doing it. This is
        not stored on the row — it opens the log with an :assignment event.
        """
      end

      argument :assigned_at, :utc_datetime_usec do
        allow_nil? true

        description """
        When the crew member picked the work up. Defaults to now. Firstmate sets
        it explicitly when backfilling work that happened before it was logged,
        so the opening event lands where it belongs in the timeline.
        """
      end

      change FirstmatePort.Changes.AssignPublicId
      change FirstmatePort.Changes.NormalizeProgressUrl
      change FirstmatePort.Portal.Changes.SeedAssignmentEvent
    end

    update :touch do
      accept [:kind, :title]
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

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :events, FirstmatePort.Portal.ProgressEvent do
      destination_attribute :item_id
      public? true
    end
  end

  identities do
    identity :unique_url, [:url] do
      where expr(url != "")
    end
  end
end
