defmodule FirstmatePort.Inbox do
  @moduledoc """
  Tenant-scoped task inbox. The Phoenix API is the only JetStream client;
  fm-steer talks HTTP only. When NATS is disabled, an ETS table holds
  messages so local tests and DEV_AUTH compose still work.
  """

  use GenServer

  @schema "fm-task-inbox.v1"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def put(tenant_slug, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put, tenant_slug, attrs})
  end

  def next(tenant_slug, task) do
    GenServer.call(__MODULE__, {:next, tenant_slug, task})
  end

  def ack(tenant_slug, ack_token) do
    GenServer.call(__MODULE__, {:ack, tenant_slug, ack_token})
  end

  def list(tenant_slug, task \\ nil) do
    GenServer.call(__MODULE__, {:list, tenant_slug, task})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:firstmate_inbox, [:named_table, :public, :ordered_set])
    {:ok, %{table: table, seq: 0}}
  end

  @impl true
  def handle_call({:put, tenant, attrs}, _from, state) do
    task = Map.get(attrs, "task") || Map.get(attrs, :task)
    body = Map.get(attrs, "body") || Map.get(attrs, :body) || ""
    delivery = Map.get(attrs, "delivery") || Map.get(attrs, :delivery) || ""

    if is_binary(task) and task != "" and body != "" do
      seq = state.seq + 1
      id = Integer.to_string(seq)

      item = %{
        "schema" => @schema,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "task" => task,
        "seq" => seq,
        "body" => body,
        "delivery" => delivery,
        "ack" => id,
        "tenant" => tenant
      }

      :ets.insert(state.table, {{tenant, seq}, :pending, item})
      {:reply, {:ok, item}, %{state | seq: seq}, {:continue, {:fanout, tenant, item}}}
    else
      {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:next, tenant, task}, _from, state) do
    match =
      :ets.foldl(
        fn
          {{^tenant, _seq}, :pending, item}, nil ->
            if is_nil(task) or task == "" or item["task"] == task, do: item, else: nil

          _, acc ->
            acc
        end,
        nil,
        state.table
      )

    case match do
      nil ->
        {:reply, :empty, state}

      item ->
        seq = item["seq"]
        :ets.insert(state.table, {{tenant, seq}, :unacked, item})
        {:reply, {:ok, item}, state}
    end
  end

  def handle_call({:ack, tenant, token}, _from, state) do
    case Integer.parse(token || "") do
      {seq, ""} ->
        :ets.delete(state.table, {tenant, seq})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, tenant, task}, _from, state) do
    items =
      :ets.foldl(
        fn
          {{^tenant, _seq}, status, item}, acc when status in [:pending, :unacked] ->
            if is_nil(task) or task == "" or item["task"] == task, do: [item | acc], else: acc

          _, acc ->
            acc
        end,
        [],
        state.table
      )

    {:reply, {:ok, Enum.sort_by(items, & &1["seq"])}, state}
  end

  @impl true
  def handle_continue({:fanout, tenant, item}, state) do
    _ = fanout(tenant, item)
    {:noreply, state}
  end

  defp fanout(tenant, item) do
    subject = FirstmatePort.Tenancy.slug(tenant) <> ".steer.inbox"
    payload = Jason.encode!(item)

    case FirstmatePort.NATS.Connection.get() do
      {:ok, conn} ->
        _ = FirstmatePort.NATS.JetstreamConsumer.ensure_owned_streams(conn, tenant)
        FirstmatePort.NATS.Connection.publish(subject, payload)

      _ ->
        :ok
    end
  end
end
