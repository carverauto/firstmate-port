defmodule FirstmatePort.Queues.Tracker do
  @moduledoc """
  In-memory register of the crew work currently in flight, per tenant.

  This is deliberately not a resource: the Queues page is a look-in at the
  present, so the state lives in this process, is capped, and ages out. Nothing
  here survives a restart, and nothing here is the store of record.

  Changed entries retained after capping are broadcast on the tenant's PubSub
  topic so the LiveView can follow along without polling. An unchanged report —
  the node's own message coming back around through JetStream — is silent.
  """

  use GenServer

  alias FirstmatePort.Queues.Entry

  @pubsub FirstmatePort.PubSub
  @topic "queues"

  # A finished task lingers long enough to be read, then leaves; work that has
  # gone quiet without ever reporting a stop leaves on the longer fuse.
  @retain_terminal_ms :timer.minutes(15)
  @retain_stale_ms :timer.hours(2)
  @max_per_tenant 200
  @sweep_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Folds one report from a worker onto the tracked entry and returns the result.
  """
  @spec track(GenServer.server(), String.t(), map()) :: {:ok, Entry.t()} | {:error, atom()}
  def track(server \\ __MODULE__, tenant, params) do
    GenServer.call(server, {:track, FirstmatePort.Tenancy.slug(tenant), params})
  end

  @doc "In-flight work first, then the most recently finished."
  @spec list(GenServer.server(), String.t()) :: [Entry.t()]
  def list(server \\ __MODULE__, tenant) do
    GenServer.call(server, {:list, FirstmatePort.Tenancy.slug(tenant)})
  end

  @doc "PubSub topic carrying `{:queue_entry, entry}` and `{:queue_removed, task}`."
  def topic(tenant), do: @topic <> ":" <> FirstmatePort.Tenancy.slug(tenant)

  @impl true
  def init(opts) do
    schedule_sweep(Keyword.get(opts, :sweep_ms, @sweep_ms))
    {:ok, %{entries: %{}, sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)}}
  end

  @impl true
  def handle_call({:track, tenant, params}, _from, state) do
    case Entry.new(tenant, params) do
      {:ok, update} ->
        key = {tenant, update.task}
        prior = Map.get(state.entries, key)
        merged = Entry.merge(prior, update)
        entries = state.entries |> Map.put(key, merged) |> cap(tenant)

        if merged != prior and Map.has_key?(entries, key) do
          Phoenix.PubSub.broadcast(@pubsub, topic(tenant), {:queue_entry, merged})
        end

        {:reply, {:ok, merged}, %{state | entries: entries}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, tenant}, _from, state) do
    {:reply, sorted(state.entries, tenant), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_ms)
    {:noreply, %{state | entries: sweep(state.entries, DateTime.utc_now())}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Drops entries that have aged past retention, announcing each removal so an
  # open look-in stops showing work that is no longer in flight.
  defp sweep(entries, now) do
    Enum.reduce(entries, %{}, fn {{tenant, task} = key, entry}, kept ->
      if expired?(entry, now) do
        Phoenix.PubSub.broadcast(@pubsub, topic(tenant), {:queue_removed, task})
        kept
      else
        Map.put(kept, key, entry)
      end
    end)
  end

  defp expired?(entry, now) do
    reference = entry.stopped_at || entry.updated_at
    budget = if Entry.terminal?(entry), do: @retain_terminal_ms, else: @retain_stale_ms

    is_nil(reference) or DateTime.diff(now, reference, :millisecond) > budget
  end

  # Bound each tenant while prioritizing active work; evict terminal entries
  # before active ones, oldest update first within each group.
  defp cap(entries, tenant) do
    ranked = sorted(entries, tenant)

    if length(ranked) <= @max_per_tenant do
      entries
    else
      ranked
      |> Enum.drop(@max_per_tenant)
      |> Enum.reduce(entries, fn entry, acc ->
        Phoenix.PubSub.broadcast(@pubsub, topic(tenant), {:queue_removed, entry.task})
        Map.delete(acc, {tenant, entry.task})
      end)
    end
  end

  defp sorted(entries, tenant) do
    entries
    |> Enum.filter(fn {{slug, _task}, _entry} -> slug == tenant end)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.sort_by(&{Entry.terminal?(&1), sort_key(&1)}, :asc)
  end

  # Ascending sort with running work first: terminal? is false before true, and
  # the negated timestamp puts the freshest report at the top of each group.
  defp sort_key(%Entry{updated_at: nil}), do: 0
  defp sort_key(%Entry{updated_at: at}), do: -DateTime.to_unix(at, :microsecond)

  defp schedule_sweep(nil), do: :ok
  defp schedule_sweep(ms), do: Process.send_after(self(), :sweep, ms)
end
