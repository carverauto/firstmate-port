defmodule FirstmatePortWeb.ProgressComponents do
  @moduledoc """
  The fleet-log progress surface, shared verbatim between the home dashboard
  preview and the standalone `/progress` page so the two can never drift.

  Everything rendered here comes from `FirstmatePort.Portal.ProgressProjection`,
  the read model over the append-only event log. The table stays compact —
  status, title, assignee, duration — and every other field lives in the details
  view, which both pages open through the same `?item=<id>` query param.

  Missing telemetry renders as "—" or an explicit "no telemetry yet", never as a
  zero. A metric nobody reported is not a metric that measured zero.
  """

  use FirstmatePortWeb, :html

  alias FirstmatePort.Portal.ProgressStatus

  @doc """
  Compact progress table.

  Clicking anywhere in a row opens the details view. The explicit Details
  control stays because a `<tr>` cannot take keyboard focus, so it is the only
  path a keyboard or screen-reader user has. The title still links to GitHub and
  carries its own binding, which is what stops a click on it from doing both.

  `detail_path` is a 1-arity function from item id to the path that opens the
  details view, so each page keeps its own query params (tab, page) while adding
  `item=`.
  """
  attr :id, :string, required: true
  attr :projections, :list, required: true
  attr :detail_path, :any, required: true

  def progress_table(assigns) do
    ~H"""
    <div class="table-wrap">
      <table class="data-table" id={@id}>
        <thead>
          <tr>
            <th scope="col" class="col-status">Status</th>
            <th scope="col">Title</th>
            <th scope="col" class="col-assignee">Assignee</th>
            <th scope="col" class="col-duration num">Duration</th>
            <th scope="col" class="col-action"><span class="visually-hidden">Details</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @projections}
            id={"row-" <> p.item.id}
            phx-click={JS.patch(@detail_path.(p.item.id))}
          >
            <td class="col-status"><.status_badge projection={p} /></td>
            <td class="cell-title">
              <a :if={linked?(p.item)} href={p.item.url} phx-click={JS.dispatch("fm:open-link")}>
                {p.item.title}
              </a>
              <span :if={not linked?(p.item)}>{p.item.title}</span>
              <span class="kind">{p.item.kind}</span>
            </td>
            <td class="col-assignee cell-assignee">{assignee_label(p)}</td>
            <td class="col-duration num">{format_duration(p.duration_ms)}</td>
            <td class="col-action cell-action">
              <.link
                patch={@detail_path.(p.item.id)}
                class="details-link"
                aria-label={"Details for " <> p.item.title}
              >
                Details
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Details view for one item, rendered as a modal over whichever page opened it.

  Closes on Esc, on an overlay click, and on the close button — all three patch
  back to `close_path`, so the browser's back button unwinds the deep link too.
  """
  attr :projection, :any, default: nil
  attr :close_path, :string, required: true
  attr :event_path, :any, default: nil

  def progress_details(assigns) do
    ~H"""
    <div
      :if={@projection}
      class="modal-root"
      id="progress-details"
      phx-window-keydown={JS.patch(@close_path)}
      phx-key="Escape"
    >
      <div class="modal-overlay" phx-click={JS.patch(@close_path)} aria-hidden="true"></div>
      <div
        class="modal-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="progress-details-title"
        phx-mounted={JS.focus_first()}
      >
        <header class="modal-head">
          <div class="modal-heading">
            <.status_badge projection={@projection} />
            <h2 id="progress-details-title">{@projection.item.title}</h2>
          </div>
          <.link patch={@close_path} class="modal-close" aria-label="Close details">Close</.link>
        </header>

        <div class="modal-body">
          <nav :if={@event_path && @projection.event_count > @projection.event_limit} class="pager" aria-label="Event pages">
            <.link :if={@projection.event_offset > 0}
              patch={@event_path.(max(0, @projection.event_offset - @projection.event_limit))}>Previous events</.link>
            <span>Event page starting at {@projection.event_offset + 1} of {@projection.event_count}.
              History sections and charts below cover this page; totals cover the full log.</span>
            <.link :if={@projection.event_offset + @projection.event_limit < @projection.event_count}
              patch={@event_path.(@projection.event_offset + @projection.event_limit)}>Next events</.link>
          </nav>
          <dl class="facts">
            <dt>Status</dt>
            <dd>
              {ProgressStatus.label(@projection.status)}
              <span :if={@projection.status_source == :kind} class="meta">
                — derived from kind; no status event yet
              </span>
              <span :if={@projection.status_at} class="meta">
                as of {format_at(@projection.status_at)}
              </span>
            </dd>

            <dt>Kind</dt>
            <dd>{@projection.item.kind}</dd>

            <dt>Link</dt>
            <dd>
              <a :if={linked?(@projection.item)} href={@projection.item.url}>
                {@projection.item.url}
              </a>
              <span :if={not linked?(@projection.item)} class="meta">no URL recorded</span>
            </dd>

            <dt>Assignee</dt>
            <dd>
              {@projection.assignee || "unassigned"}

            </dd>

            <dt>Duration</dt>
            <dd>
              {format_duration(@projection.duration_ms)}
              <span :if={is_nil(@projection.duration_ms)} class="meta">no telemetry yet</span>
            </dd>

            <dt>Tokens</dt>
            <dd>
              {format_tokens(@projection.tokens)}
              <span :if={is_nil(@projection.tokens)} class="meta">no telemetry yet</span>
            </dd>

            <dt>Interrupted</dt>
            <dd>{interrupted_label(@projection.interrupted)}</dd>

            <dt>Started</dt>
            <dd>
              {format_at(@projection.started_at)}
              <span :if={is_nil(@projection.started_at)} class="meta">no events yet</span>
            </dd>

            <dt>Completed</dt>
            <dd>
              {format_at(@projection.completed_at)}
              <span :if={is_nil(@projection.completed_at)} class="meta">still open</span>
            </dd>

            <dt>Elapsed</dt>
            <dd>
              {format_duration(@projection.elapsed_ms)}
              <span class="meta">
                start to completion, from the log's own timestamps
              </span>
            </dd>

            <dt>Recorded</dt>
            <dd>{format_at(@projection.item.inserted_at)}</dd>
          </dl>

          <section :if={@projection.status_spans != []} class="modal-section">
            <h3>Time in each status</h3>
            <.status_timeline spans={@projection.status_spans} />
          </section>

          <section :if={@projection.contributions != []} class="modal-section">
            <h3>Who spent what</h3>
            <.h_bars
              label="Tokens by contributor"
              bars={contributor_bars(@projection)}
            />
          </section>

          <section class="modal-section">
            <h3>Heuristics</h3>
            <p class="hint">Derived from the log, not reported.</p>
            <ul class="heuristics">
              <li :for={{tag, text} <- heuristics(@projection)}>
                <span class="heuristic-tag">{tag}</span>
                <span>{text}</span>
              </li>
            </ul>
          </section>

          <section class="modal-section">
            <h3>Contributions</h3>
            <p :if={@projection.contributions == []} class="empty-copy">
              No contributions reported on this page. Producers append them; see docs/progress.md.
            </p>
            <div :if={@projection.contributions != []} class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th scope="col">Worker</th>
                    <th scope="col">Role</th>
                    <th scope="col">Runtime</th>
                    <th scope="col">Model</th>
                    <th scope="col">Effort</th>
                    <th scope="col" class="num">Duration</th>
                    <th scope="col" class="num">Tokens</th>
                    <th scope="col">When</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={c <- @projection.contributions}>
                    <td>{c.worker}</td>
                    <td>
                      <span class={["role", c.role == :review && "role-review"]}>
                        {c.role || "—"}
                      </span>
                    </td>
                    <td>{blank(c.runtime)}</td>
                    <td>{blank(c.model)}</td>
                    <td>{blank(c.effort)}</td>
                    <td class="num">{format_duration(c.duration_ms)}</td>
                    <td class="num">{format_tokens(c.tokens)}</td>
                    <td class="meta">{format_at(c.occurred_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="modal-section">
            <h3>Assignment history</h3>
            <p :if={@projection.assignments == []} class="empty-copy">
              No assignment events on this page.
            </p>
            <ol class="rows">
              <li :for={a <- @projection.assignments}>
                <span>
                  {event_summary(a)}
                  <span :if={present?(a.detail)} class="meta">{a.detail}</span>
                </span>
                <span class="meta">{format_at(a.occurred_at)}</span>
              </li>
            </ol>
          </section>

          <section class="modal-section">
            <h3>Event log</h3>
            <p class="hint">
              Append-only. Every line below was added, never edited.
            </p>
            <p :if={@projection.events == []} class="empty-copy">
              Nothing appended yet. This row is showing its derived defaults.
            </p>
            <ol class="rows">
              <li :for={e <- @projection.events}>
                <span>
                  <span class="kind">{e.type}</span>
                  {event_summary(e)}
                </span>
                <span class="meta">{format_at(e.occurred_at)}</span>
              </li>
            </ol>
          </section>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Status pill. Colour is never the only cue: the label is always present, and a
  status the log never reported is marked as derived.
  """
  attr :projection, :any, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      class={["badge", "badge-" <> to_string(@projection.status)]}
      title={@projection.status_source == :kind && "No status event yet — derived from kind"}
    >
      <span class="badge-dot" aria-hidden="true"></span>
      {ProgressStatus.label(@projection.status)}<span
        :if={@projection.status_source == :kind}
        class="badge-derived"
      >*</span>
    </span>
    """
  end

  @doc """
  The `/progress` charts. Each one says so plainly when nothing has reported the
  metric it draws, rather than drawing a zero.
  """
  attr :stats, :map, required: true
  attr :capped, :boolean, default: false

  def progress_charts(assigns) do
    ~H"""
    <section class="plate viz">
      <h2>Fleet telemetry</h2>
      <p :if={@capped} class="hint">
        Charted over the newest {@stats.total} items. Older rows are on the pages below.
      </p>

      <div class="kpis">
        <.kpi label="Items" value={Integer.to_string(@stats.total)} note="in this tenant" />
        <.kpi
          label="Tokens spent"
          value={format_tokens(@stats.tokens_total)}
          note={tracked_note(@stats.tokens_tracked, @stats.total)}
        />
        <.kpi
          label="Time on task"
          value={format_duration(@stats.duration_total_ms)}
          note={tracked_note(@stats.duration_tracked, @stats.total)}
        />
        <.kpi
          label="Interrupted"
          value={reported_count(@stats.interrupted_counts.yes, @stats.interrupted_tracked)}
          note={tracked_note(@stats.interrupted_tracked, @stats.total)}
        />
      </div>

      <div class="charts">
        <figure class="chart">
          <figcaption>Status mix</figcaption>
          <p :if={@stats.total == 0} class="empty-copy">No progress rows yet.</p>
          <.h_bars
            :if={@stats.total > 0}
            label="Rows by status"
            bars={
              for {s, i} <- Enum.with_index(ProgressStatus.all()) do
                %{
                  slot: i + 1,
                  label: ProgressStatus.label(s),
                  count: Map.fetch!(@stats.status_counts, s)
                }
              end
            }
          />
        </figure>

        <figure class="chart">
          <figcaption>Duration distribution</figcaption>
          <p :if={@stats.duration_tracked == 0} class="empty-copy">
            No telemetry yet. Nothing has reported how long a task took.
          </p>
          <.column_chart
            :if={@stats.duration_tracked > 0}
            buckets={@stats.duration_buckets}
            label="Items by reported duration"
          />
          <figcaption :if={@stats.duration_tracked > 0} class="meta">
            {@stats.duration_tracked} of {@stats.total} items reported a duration.
          </figcaption>
        </figure>

        <figure class="chart">
          <figcaption>Interrupted</figcaption>
          <.stacked_bar
            segments={[
              %{key: "no", label: "clean", count: @stats.interrupted_counts.no},
              %{key: "yes", label: "interrupted", count: @stats.interrupted_counts.yes},
              %{key: "unknown", label: "unknown", count: @stats.interrupted_counts.unknown}
            ]}
            total={@stats.total}
            empty="No progress rows yet."
          />
        </figure>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true

  defp kpi(assigns) do
    ~H"""
    <div class="kpi">
      <span class="kpi-label">{@label}</span>
      <span class="kpi-value">{@value}</span>
      <span class="kpi-note">{@note}</span>
    </div>
    """
  end

  # One bar per class, ordered by lifecycle. At seven statuses a stacked bar is
  # a smear; separate bars stay readable, and every bar carries its label and
  # count as text - the relief the light-mode contrast warning obliges.
  attr :bars, :list, required: true
  attr :label, :string, required: true

  defp h_bars(assigns) do
    max = assigns.bars |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end) |> max(1)

    assigns =
      assigns
      |> assign(:max, max)
      |> assign(
        :summary,
        Enum.map_join(assigns.bars, ", ", &"#{&1.label}: #{Map.get(&1, :display) || &1.count}")
      )

    ~H"""
    <div class="hbars" role="img" aria-label={"#{@label}. #{@summary}"}>
      <div :for={b <- @bars} class="hbar">
        <span class="hbar-label">{b.label}</span>
        <span class="hbar-track">
          <span
            :if={b.count > 0}
            class={"hbar-fill seg-#{b.slot}"}
            style={"width: #{percent(b.count, @max)}%"}
          >
          </span>
        </span>
        <span class="hbar-value num">{Map.get(b, :display) || b.count}</span>
      </div>
    </div>
    """
  end

  # Part-to-whole across at most three classes. Every segment is direct-labelled
  # in the legend with its count, which is also the table view the light-mode
  # contrast warning obliges.
  attr :segments, :list, required: true
  attr :total, :integer, required: true
  attr :empty, :string, required: true

  defp stacked_bar(assigns) do
    ~H"""
    <p :if={@total == 0} class="empty-copy">{@empty}</p>
    <div :if={@total > 0}>
      <div class="bar" role="img" aria-label={bar_summary(@segments, @total)}>
        <span
          :for={{s, i} <- Enum.with_index(@segments)}
          :if={s.count > 0}
          class={"bar-seg seg-#{i + 1} seg-#{s.key}"}
          style={"flex-basis: #{percent(s.count, @total)}%"}
        >
        </span>
      </div>
      <ul class="legend">
        <li :for={{s, i} <- Enum.with_index(@segments)}>
          <span class={"swatch seg-#{i + 1} seg-#{s.key}"} aria-hidden="true"></span>
          <span class="legend-label">{s.label}</span>
          <span class="legend-value num">{s.count}</span>
        </li>
      </ul>
    </div>
    """
  end

  # One ordered series, one hue. Counts sit above their column so no reader has
  # to measure a bar against a gridline.
  attr :buckets, :list, required: true
  attr :label, :string, required: true

  defp column_chart(assigns) do
    max = assigns.buckets |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end) |> max(1)

    assigns =
      assigns
      |> assign(:max, max)
      |> assign(:summary, Enum.map_join(assigns.buckets, ", ", &"#{&1.label}: #{&1.count}"))

    ~H"""
    <div class="columns" role="img" aria-label={"#{@label}. #{@summary}"}>
      <div :for={b <- @buckets} class="column">
        <span class="column-value num">{b.count}</span>
        <span class="column-track">
          <span class="column-fill" style={"height: #{percent(b.count, @max)}%"}></span>
        </span>
        <span class="column-label">{b.label}</span>
      </div>
    </div>
    """
  end

  # One segment per status the item held, width proportional to how long it
  # held it. Spans whose end is unknown are still drawn, but the key says so
  # rather than inventing a duration.
  attr :spans, :list, required: true

  defp status_timeline(assigns) do
    total = assigns.spans |> Enum.map(&(&1.duration_ms || 0)) |> Enum.sum() |> max(1)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(
        :summary,
        Enum.map_join(assigns.spans, ", ", fn s ->
          "#{ProgressStatus.label(s.status)}: #{format_duration(s.duration_ms)}"
        end)
      )

    ~H"""
    <div class="timeline" role="img" aria-label={"Time in each status. " <> @summary}>
      <span
        :for={s <- @spans}
        class={"timeline-seg " <> slot_class(s.status)}
        style={"flex-basis: #{percent(s.duration_ms || 0, @total)}%"}
        title={ProgressStatus.label(s.status)}
      >
      </span>
    </div>
    <ul class="timeline-key">
      <li :for={s <- @spans}>
        <span class={"swatch " <> slot_class(s.status)} aria-hidden="true"></span>
        <span class="legend-label">{ProgressStatus.label(s.status)}</span>
        <span class="legend-value num">{format_duration(s.duration_ms)}</span>
        <span :if={s.open?} class="meta">no next status in this page</span>
      </li>
    </ul>
    """
  end

  @doc """
  The palette slot a status owns, so its colour is the same in the badge, the
  status-mix chart, and the timeline.
  """
  def slot_class(status) do
    case Enum.find_index(ProgressStatus.all(), &(&1 == status)) do
      nil -> "seg-unknown"
      index -> "seg-#{index + 1}"
    end
  end

  @doc """
  Tokens spent per contributor, biggest first, for the details view.

  Contributors who reported no tokens still get a row at zero, because "this
  worker contributed and reported nothing" is worth seeing.
  """
  def contributor_bars(projection) do
    projection.contributions
    |> Enum.group_by(& &1.worker)
    |> Enum.map(fn {worker, events} ->
      reported = for event <- events, is_integer(event.tokens), do: event.tokens
      tokens = Enum.sum(reported)
      review? = Enum.any?(events, &(&1.role == :review))

      %{
        slot: if(review?, do: 4, else: 1),
        label: if(review?, do: worker <> " (review)", else: worker),
        count: tokens,
        display: format_tokens(if(reported == [], do: nil, else: tokens))
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc """
  Honest observations the log supports, as `{tag, sentence}` pairs.

  Every line is derived from timestamps and counts already in the log. Nothing
  here guesses at a status the crew did not report; "looks stalled" is phrased
  as an observation about silence, not as the `:stalled` status itself.
  """
  def heuristics(projection, now \\ DateTime.utc_now()) do
    []
    |> then(&(&1 ++ pace_heuristic(projection)))
    |> then(&(&1 ++ silence_heuristic(projection, now)))
    |> then(&(&1 ++ review_heuristic(projection)))
    |> then(&(&1 ++ hands_heuristic(projection)))
    |> then(&(&1 ++ interrupt_heuristic(projection)))
    |> case do
      [] -> [{"log", "Nothing appended yet, so there is nothing to observe."}]
      lines -> lines
    end
  end

  defp pace_heuristic(%{elapsed_ms: nil}), do: []

  defp pace_heuristic(%{elapsed_ms: elapsed, duration_ms: nil}) do
    [{"elapsed", "Ran #{format_duration(elapsed)} from first event to completion."}]
  end

  defp pace_heuristic(%{elapsed_ms: elapsed, duration_ms: reported}) do
    [
      {"elapsed",
       "Ran #{format_duration(elapsed)} start to finish; " <>
         "#{format_duration(reported)} of that was reported work."}
    ]
  end

  defp silence_heuristic(%{last_event_at: nil}, _now), do: []

  defp silence_heuristic(projection, now) do
    idle = DateTime.diff(now, projection.last_event_at, :millisecond)

    cond do
      not is_nil(projection.completed_at) ->
        []

      idle >= 604_800_000 ->
        [{"quiet", "No events for #{format_duration(idle)}. Nobody has moved this in a while."}]

      idle >= 86_400_000 ->
        [{"quiet", "No events for #{format_duration(idle)}."}]

      true ->
        []
    end
  end

  defp review_heuristic(%{reviewers: []}), do: []

  defp review_heuristic(projection) do
    reviewers = projection.reviewers |> Enum.map(& &1.worker) |> Enum.uniq()
    [{"review", "Reviewed by #{Enum.join(reviewers, ", ")}."}]
  end

  defp hands_heuristic(%{workers: workers, worker_count: count}) when count > 1 do
    names = Enum.join(workers, ", ")
    suffix = if count > length(workers), do: " (first #{length(workers)} shown)", else: ""
    [{"hands", "#{count} crew members touched this: #{names}#{suffix}."}]
  end

  defp hands_heuristic(_projection), do: []

  defp interrupt_heuristic(%{interrupted: :yes}) do
    [{"interrupt", "Interrupted at least once."}]
  end

  defp interrupt_heuristic(_projection), do: []

  @doc """
  Short assignee cell: who holds it now, plus how many others touched it. The
  full list is one click away in the details view.
  """
  def assignee_label(projection) do
    extra = max(projection.worker_count - 1, 0)

    case {projection.assignee, extra} do
      {nil, _} -> "unassigned"
      {name, 0} -> name
      {name, n} -> "#{name} +#{n}"
    end
  end

  @doc "Compact duration, or an em dash when nothing reported one."
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  def format_duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  def format_duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"

  def format_duration(ms) when ms < 86_400_000 do
    hours = div(ms, 3_600_000)
    minutes = div(rem(ms, 3_600_000), 60_000)
    if minutes == 0, do: "#{hours}h", else: "#{hours}h #{minutes}m"
  end

  def format_duration(ms) do
    days = div(ms, 86_400_000)
    hours = div(rem(ms, 86_400_000), 3_600_000)
    if hours == 0, do: "#{days}d", else: "#{days}d #{hours}h"
  end

  @doc "Token counts short enough for a table cell."
  def format_tokens(nil), do: "—"
  def format_tokens(n) when n < 1_000, do: Integer.to_string(n)
  def format_tokens(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  def format_tokens(n), do: "#{Float.round(n / 1_000_000, 2)}M"

  @doc "yes / no / unknown, spelled out."
  def interrupted_label(:yes), do: "yes"
  def interrupted_label(:no), do: "no"
  def interrupted_label(_), do: "unknown"

  @doc "UTC timestamp trimmed to the minute."
  def format_at(nil), do: "—"

  def format_at(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp event_summary(%{type: :status} = e), do: ProgressStatus.label(e.status)

  defp event_summary(%{type: type} = e) when type in [:assignment, :contribution] do
    [
      e.worker,
      e.role && "(#{e.role})",
      blank_or_nil(e.runtime),
      blank_or_nil(e.model),
      blank_or_nil(e.effort)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp event_summary(%{type: :interruption} = e), do: "interrupted: #{e.interrupted}"
  defp event_summary(e), do: blank(e.detail)

  # Ash casts an empty string to nil on the way into the database, so "not set"
  # arrives as nil here even where the attribute's default is "".
  defp present?(value), do: is_binary(value) and value != ""

  defp linked?(%{url: url}), do: present?(url)

  defp blank_or_nil(value), do: if(present?(value), do: value, else: nil)

  defp blank(value), do: if(present?(value), do: value, else: "—")

  defp tracked_note(0, _total), do: "no telemetry yet"
  defp tracked_note(tracked, total), do: "#{tracked} of #{total} reported"

  # "0 interrupted" would read as "none were", which is not what an empty log
  # says. Nothing reported stays an em dash, like the other telemetry tiles.
  defp reported_count(_count, 0), do: "—"
  defp reported_count(count, _tracked), do: Integer.to_string(count)

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: Float.round(count * 100 / total, 2)

  defp bar_summary(segments, total) do
    segments
    |> Enum.map_join(", ", &"#{&1.label}: #{&1.count}")
    |> Kernel.<>(" of #{total}")
  end
end
