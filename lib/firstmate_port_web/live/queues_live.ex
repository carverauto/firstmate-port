defmodule FirstmatePortWeb.QueuesLive do
  @moduledoc """
  Live look-in at the crew work in flight for the signed-in tenant: what was
  sent to which worker, its agent id, model and effort, token usage, and how
  long it has been running.

  Rows come from `FirstmatePort.Queues.Tracker`, which is memory only. Nothing
  on this page is the store of record — the fleet log holds that.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Queues
  alias FirstmatePort.Queues.Entry

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  # Elapsed time is the only thing that moves on its own, so the clock ticks
  # rather than the data.
  @tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    tenant = FirstmatePort.Tenancy.slug(socket.assigns.current_user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Queues.topic(tenant))

      Phoenix.PubSub.subscribe(
        FirstmatePort.PubSub,
        FirstmatePort.NATS.QueueListener.topic(tenant)
      )

      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "queues")
     |> assign(:tenant, tenant)
     |> assign(:connected, FirstmatePort.NATS.Connection.connected?())
     |> assign(:now, DateTime.utc_now())
     |> assign(:events, [])
     |> assign_entries(Queues.list(tenant))}
  end

  @impl true
  def handle_info({:queue_entry, %Entry{} = entry}, socket) do
    {:noreply,
     socket
     |> assign_entries([entry | Enum.reject(socket.assigns.entries, &(&1.task == entry.task))])
     |> assign(:connected, FirstmatePort.NATS.Connection.connected?())}
  end

  def handle_info({:queue_removed, task}, socket) do
    {:noreply, assign_entries(socket, Enum.reject(socket.assigns.entries, &(&1.task == task)))}
  end

  def handle_info({:nats_event, event}, socket) do
    {:noreply, assign(socket, :events, Enum.take([event | socket.assigns.events], 50))}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:connected, FirstmatePort.NATS.Connection.connected?())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Queues</h1>
        <p class="meta">
          {@active_count} in flight · {@finished_count} finished · {if @connected,
            do: "NATS connected",
            else: "NATS not connected"}
        </p>
      </header>

      <section class="plate">
        <h2>workers</h2>
        <p :if={@entries == []} class="empty-state">
          No work in flight. Workers report through fm-steer as firstmate hands out tasks —
          task, worker, agent id, model, effort, tokens, and start/stop times land here.
          This is a live look-in at the queues, not the fleet log.
        </p>
        <div :if={@entries != []} class="queue-scroll">
          <table class="queue-table">
            <thead>
              <tr>
                <th>task</th>
                <th>worker</th>
                <th>agent</th>
                <th>status</th>
                <th>model / effort</th>
                <th class="num">tokens</th>
                <th class="num">elapsed</th>
                <th>started</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @entries}>
                <td>
                  <span class="queue-task">{entry.task}</span>
                  <span :if={entry.summary} class="queue-summary">{entry.summary}</span>
                </td>
                <td>{entry.worker || "—"}</td>
                <td class="kind">{entry.agent_id || "—"}</td>
                <td>
                  <span class="queue-status" data-status={entry.status}>
                    {status_label(entry.status)}
                  </span>
                </td>
                <td>{model_effort(entry)}</td>
                <td class="num">{tokens_label(entry)}</td>
                <td class="num">{elapsed(entry, @now)}</td>
                <td class="meta">{started_label(entry)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="plate">
        <h2>traffic</h2>
        <p :if={@events == []} class="empty-copy">
          Raw subjects appear here as they arrive. Durable consumers watch
          &lt;tenant&gt;.steer.&gt; — queue facts ride &lt;tenant&gt;.steer.queue —
          and &lt;tenant&gt;.discord.inbound.
        </p>
        <ol :if={@events != []} class="rows">
          <li :for={event <- @events}>
            <span>
              <span class="kind">{event.subject}</span>
              <time>{event.at}</time>
            </span>
            <pre>{event.body}</pre>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  defp assign_entries(socket, entries) do
    entries = Enum.sort_by(entries, &{Entry.terminal?(&1), sort_key(&1)}, :asc)

    active = Enum.count(entries, &(not Entry.terminal?(&1)))

    socket
    |> assign(:entries, entries)
    |> assign(:active_count, active)
    |> assign(:finished_count, length(entries) - active)
  end

  defp sort_key(%Entry{updated_at: nil}), do: 0
  defp sort_key(%Entry{updated_at: at}), do: -DateTime.to_unix(at, :microsecond)

  defp status_label(nil), do: "queued"
  defp status_label(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp model_effort(%Entry{model: nil, effort: nil}), do: "—"
  defp model_effort(%Entry{model: model, effort: nil}), do: model
  defp model_effort(%Entry{model: nil, effort: effort}), do: "· " <> effort
  defp model_effort(%Entry{model: model, effort: effort}), do: model <> " · " <> effort

  defp tokens_label(entry) do
    case Entry.tokens_total(entry) do
      0 -> "—"
      total -> group_digits(total)
    end
  end

  # Token totals run to six figures, and an ungrouped run of digits is the kind
  # of number nobody actually reads.
  defp group_digits(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp started_label(%Entry{started_at: nil}), do: "—"
  defp started_label(%Entry{started_at: at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%SZ")

  defp elapsed(entry, now) do
    case Entry.duration_ms(entry, now) do
      nil -> "—"
      ms -> humanize(div(ms, 1000))
    end
  end

  defp humanize(seconds) when seconds < 60, do: "#{seconds}s"

  defp humanize(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp humanize(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
end
