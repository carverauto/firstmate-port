defmodule FirstmatePort.Portal.ProgressProjection do
  @moduledoc """
  Read model over the append-only `FirstmatePort.Portal.ProgressEvent` log.

  Nothing here writes. A projection folds one item's events into the shape the
  fleet log, the `/progress` table, the details view, and the charts all need:
  newest event wins for the single-value fields (status, assignee), while
  bounded pages expose the complete history in the details view.

  Every derived number is honest about missing data. Duration, tokens, and
  interrupted are `nil`/`:unknown` until an event reports them — they are never
  invented from wall-clock time or from a PR author.
  """

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem, ProgressStatus, ProgressSummary}

  @typedoc "yes / no / unknown, because 'nobody said' is not the same as 'no'."
  @type interrupted :: :yes | :no | :unknown

  defstruct [
    :item,
    :status,
    :status_source,
    :status_at,
    :assignee,
    :assignee_source,
    :assignments,
    :contributions,
    :workers,
    :reviewers,
    :duration_ms,
    :tokens,
    :interrupted,
    :started_at,
    :completed_at,
    :elapsed_ms,
    :status_spans,
    :first_event_at,
    :last_event_at,
    :events,
    :event_count,
    :event_offset,
    :event_limit,
    :review_count,
    :worker_count
  ]

  @doc """
  Whole-tenant aggregation is capped so a chart can never become an unbounded
  table scan. When more items exist than this, the charts say so.
  """
  defdelegate stats_cap(), to: ProgressItem

  @doc """
  Folds one item plus its events into a projection.

  Events may arrive in any order; they are sorted oldest-first here so the
  function is safe to call on a hand-built list.
  """
  def project(item, events) when is_list(events) do
    events = sort_events(events)

    status_event = last_of(events, :status)
    assignment_events = Enum.filter(events, &(&1.type == :assignment))
    contributions = Enum.filter(events, &(&1.type == :contribution))
    last_assignment = List.last(assignment_events)
    status = (status_event && status_event.status) || ProgressStatus.default_for_kind(item.kind)
    started_at = events |> List.first() |> occurred_at()
    completed_at = completed_at(status, status_event)

    %__MODULE__{
      item: item,
      status: status,
      status_source: if(status_event, do: :log, else: :kind),
      status_at: status_event && status_event.occurred_at,
      assignee: last_assignment && last_assignment.worker,
      assignee_source: if(last_assignment, do: :assignment),
      assignments: Enum.reverse(assignment_events),
      contributions: contributions,
      workers: workers(assignment_events ++ contributions),
      reviewers: Enum.filter(contributions, &(&1.role == :review)),
      duration_ms: sum_known(events, :duration_ms),
      tokens: sum_known(events, :tokens),
      interrupted: interrupted(events),
      started_at: started_at,
      completed_at: completed_at,
      elapsed_ms: elapsed_ms(started_at, completed_at),
      status_spans: status_spans(events, status_event),
      first_event_at: started_at,
      last_event_at: events |> List.last() |> occurred_at(),
      events: events,
      event_count: length(events),
      event_offset: 0,
      event_limit: 100,
      review_count: Enum.count(contributions, &(&1.role == :review)),
      worker_count: length(workers(assignment_events ++ contributions))
    }
  end

  # The work is complete only if it is *currently* in a terminal status. A row
  # that merged and then came back to in-progress has no completion date.
  defp completed_at(status, status_event) do
    if ProgressStatus.terminal?(status) and status_event, do: status_event.occurred_at
  end

  defp elapsed_ms(nil, _completed), do: nil
  defp elapsed_ms(_started, nil), do: nil

  defp elapsed_ms(started, completed), do: DateTime.diff(completed, started, :millisecond)

  @doc """
  How long the item held each status, oldest first.

  Each span runs from its own status event to the next one; the last span is
  open-ended (`to: nil`) unless the item reached a terminal status. Spans are
  measured from real event timestamps, so an item with a single status event and
  no ending has a `duration_ms` of `nil` rather than a guess.
  """
  def status_spans(events, status_event) do
    statuses = Enum.filter(events, &(&1.type == :status))
    closed? = status_event && ProgressStatus.terminal?(status_event.status)

    statuses
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.map(fn
      [event, nil] ->
        span(event, if(closed?, do: event.occurred_at, else: nil), not closed?)

      [event, next] ->
        span(event, next.occurred_at, false)
    end)
    # A terminal status the item is still sitting in has no width: it is where
    # the work ended, not somewhere it spent time. Drawing a 0ms segment for it
    # only invites the reader to wonder what it means.
    |> Enum.reject(&(&1.duration_ms == 0 and not &1.open?))
  end

  defp span(event, to, open?) do
    %{
      status: event.status,
      from: event.occurred_at,
      to: to,
      open?: open?,
      duration_ms: to && DateTime.diff(to, event.occurred_at, :millisecond)
    }
  end

  @doc "Projects a bounded item page using database summaries, without loading histories."
  def load(items, opts) when is_list(items) do
    with {:ok, summaries} <- ProgressSummary.load(Enum.map(items, & &1.id), opts) do
      {:ok, Enum.map(items, &apply_summary(project(&1, []), Map.get(summaries, &1.id)))}
    end
  end

  @doc "Loads one bounded event page and the full database summary."
  def load_one(item, opts, limit \\ 100, offset \\ 0) do
    with {:ok, [summary]} <- load([item], opts),
         {:ok, events} <-
           ProgressEvent.list_for_item(item.id, %{limit: limit, offset: offset}, opts) do
      page = project(item, events)

      {:ok,
       %{
         summary
         | events: events,
           event_limit: limit,
           event_offset: offset,
           assignments: page.assignments,
           contributions: page.contributions,
           reviewers: page.reviewers,
           status_spans: page.status_spans
       }}
    end
  end

  def parse_offset(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  def parse_offset(_), do: 0

  defp apply_summary(projection, nil), do: projection

  defp apply_summary(projection, summary) do
    status = summary.status || ProgressStatus.default_for_kind(projection.item.kind)
    completed = if ProgressStatus.terminal?(status), do: summary.status_at

    struct!(
      projection,
      Map.merge(summary, %{
        status: status,
        status_source: if(summary.status, do: :log, else: :kind),
        assignee_source: if(summary.assignee, do: :assignment),
        first_event_at: summary.started_at,
        completed_at: completed,
        elapsed_ms: elapsed_ms(summary.started_at, completed)
      })
    )
  end

  @doc """
  Aggregates a list of projections into everything the `/progress` charts draw.

  Counts that nothing has reported come back as zero with a matching `*_tracked`
  count, so the page can say "no telemetry yet" instead of drawing a zero line
  and implying the answer is zero.
  """
  def stats(projections) when is_list(projections) do
    durations = for p <- projections, is_integer(p.duration_ms), do: p.duration_ms
    tokens = for p <- projections, is_integer(p.tokens), do: p.tokens

    %{
      total: length(projections),
      status_counts: count_by(projections, & &1.status, ProgressStatus.all()),
      duration_buckets: duration_buckets(durations),
      duration_tracked: length(durations),
      duration_total_ms: if(durations == [], do: nil, else: Enum.sum(durations)),
      tokens_tracked: length(tokens),
      tokens_total: if(tokens == [], do: nil, else: Enum.sum(tokens)),
      interrupted_counts: count_by(projections, & &1.interrupted, [:yes, :no, :unknown]),
      interrupted_tracked: Enum.count(projections, &(&1.interrupted != :unknown)),
      completed: Enum.count(projections, &(not is_nil(&1.completed_at))),
      worker_total: projections |> Enum.flat_map(& &1.workers) |> Enum.uniq() |> length(),
      review_total: Enum.count(projections, &(&1.review_count > 0))
    }
  end

  @doc """
  Aggregates the charts for a whole tenant, newest items first and capped at
  `stats_cap/0`.

  Returns `{:ok, stats, capped?}`; `capped?` is true when the tenant holds more
  items than the charts looked at, which the page then says out loud.
  """
  def tenant_stats(opts) do
    with {:ok, items} <- ProgressItem.list_for_stats(opts),
         {:ok, projections} <- load(items, opts),
         {:ok, total} <- Ash.count(ProgressItem, opts),
         {:ok, workers} <- ProgressSummary.worker_total(Enum.map(items, & &1.id), opts) do
      {:ok, Map.put(stats(projections), :worker_total, workers), total > length(items)}
    end
  end

  @doc """
  Duration histogram buckets, in order. Labels are the x-axis of the chart, so
  they stay short.
  """
  def duration_bucket_labels, do: ["<5m", "5–15m", "15–60m", "1–4h", "4h+"]

  defp duration_buckets(durations) do
    counts = Enum.frequencies_by(durations, &duration_bucket/1)

    duration_bucket_labels()
    |> Enum.map(&%{label: &1, count: Map.get(counts, &1, 0)})
  end

  defp duration_bucket(ms) when ms < 300_000, do: "<5m"
  defp duration_bucket(ms) when ms < 900_000, do: "5–15m"
  defp duration_bucket(ms) when ms < 3_600_000, do: "15–60m"
  defp duration_bucket(ms) when ms < 14_400_000, do: "1–4h"
  defp duration_bucket(_ms), do: "4h+"

  defp count_by(projections, fun, keys) do
    counts = Enum.frequencies_by(projections, fun)
    Map.new(keys, &{&1, Map.get(counts, &1, 0)})
  end

  defp workers(events) do
    events
    |> Enum.map(& &1.worker)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp sum_known(events, field) do
    values = for e <- events, is_integer(Map.fetch!(e, field)), do: Map.fetch!(e, field)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp interrupted(events) do
    reported = for e <- events, is_boolean(e.interrupted), do: e.interrupted

    cond do
      reported == [] -> :unknown
      Enum.any?(reported) -> :yes
      true -> :no
    end
  end

  defp last_of(events, type) do
    events |> Enum.filter(&(&1.type == type)) |> List.last()
  end

  defp occurred_at(nil), do: nil
  defp occurred_at(event), do: event.occurred_at

  defp sort_events(events) do
    Enum.sort(events, fn a, b ->
      case DateTime.compare(a.occurred_at, b.occurred_at) do
        :lt ->
          true

        :gt ->
          false

        :eq ->
          case DateTime.compare(a.inserted_at, b.inserted_at) do
            :lt -> true
            :gt -> false
            :eq -> a.id <= b.id
          end
      end
    end)
  end
end
