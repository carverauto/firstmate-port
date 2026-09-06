defmodule FirstmatePort.BuildEvents do
  @moduledoc """
  Run projections over the append-only `FirstmatePort.Portal.BuildEvent` log.

  The log keeps every report the crew posted. A dashboard row is one run,
  folded from that run's events oldest to newest, so a projection never
  requires rewriting history.

  See `docs/build-events.md` for field precedence, timestamp selection, and
  cumulative token reporting.
  """

  alias FirstmatePort.Portal.BuildEvent

  @carried [
    :kind,
    :target,
    :agent_id,
    :model,
    :effort,
    :image,
    :image_tag,
    :cluster,
    :namespace,
    :outcome
  ]

  @doc """
  Projected runs, most recent activity first.

  `:limit` caps the number of runs returned; the remaining `opts` go to Ash
  (`:actor`, `:tenant`), so pass `FirstmatePort.Tenancy.opts(actor)`.
  """
  def runs(opts \\ []) do
    {limit, read_opts} = Keyword.pop(opts, :limit)

    with {:ok, events} <- BuildEvent.list(read_opts) do
      {:ok, events |> project() |> cap(limit)}
    end
  end

  @doc "The projection for a single run id."
  def run(run_id, opts \\ []) do
    with {:ok, events} <- BuildEvent.for_run(run_id, opts) do
      case project(events) do
        [run] -> {:ok, run}
        [] -> {:error, :not_found}
      end
    end
  end

  defp project(events) do
    events
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.group_by(& &1.run_id)
    |> Enum.map(fn {run_id, run_events} -> fold(run_id, run_events) end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp fold(run_id, [first | _] = events) do
    last = List.last(events)

    @carried
    |> Map.new(fn field -> {field, newest(events, field, "")} end)
    |> Map.merge(%{
      run_id: run_id,
      id: last.id,
      status: last.status,
      finished?: last.status != :started,
      tokens: newest(events, :tokens, 0),
      started_at: oldest_time(events, :started_at) || first.inserted_at,
      finished_at: newest_time(events, :finished_at),
      events: length(events),
      updated_at: last.inserted_at
    })
    |> put_duration()
  end

  defp newest(events, field, blank) do
    Enum.reduce(events, blank, fn event, acc ->
      case Map.get(event, field) do
        value when value in [nil, blank] -> acc
        value -> value
      end
    end)
  end

  defp oldest_time(events, field), do: events |> times(field) |> List.first()
  defp newest_time(events, field), do: events |> times(field) |> List.last()

  defp times(events, field) do
    events |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)
  end

  defp put_duration(
         %{started_at: %DateTime{} = started, finished_at: %DateTime{} = finished} = run
       ) do
    Map.put(run, :duration_ms, DateTime.diff(finished, started, :millisecond))
  end

  defp put_duration(run), do: Map.put(run, :duration_ms, nil)

  defp cap(runs, limit) when is_integer(limit) and limit > 0, do: Enum.take(runs, limit)
  defp cap(runs, _limit), do: runs
end
