defmodule FirstmatePort.Inbox do
  @moduledoc """
  The message bus between firstmate, the second mate, and the crew.

  Shared store for the HTTP CLI and portal UI. Routing, delivery semantics,
  persistence, and the separate on-disk stores are documented in `docs/inbox.md`.
  """

  require Ash.Query

  alias FirstmatePort.Portal.InboxMessage
  alias FirstmatePort.Tenancy

  @schema "fm-task-inbox.v1"
  @default_task "firstmate"
  @pubsub FirstmatePort.PubSub
  @topic "inbox"

  @doc "The task a message with no task of its own belongs to."
  def default_task, do: @default_task

  @doc "The `fm-task-inbox.v1` schema string carried on every payload."
  def schema, do: @schema

  @doc "Tenant-scoped PubSub topic the portal subscribes to."
  def topic(tenant), do: @topic <> ":" <> Tenancy.slug(tenant)

  @doc """
  Files a message.

  `attrs` are raw request params, so string and atom keys are both read. A blank
  task becomes `default_task/0` rather than an error: the second mate reporting
  "this is done" should not have to know a routing key.
  """
  def put(actor, attrs) when is_map(attrs) do
    task = attrs |> fetch(:task) |> presence() || @default_task
    body = attrs |> fetch(:body) |> presence()
    delivery = attrs |> fetch(:delivery) |> presence() || ""

    if body do
      insert(actor, %{task: task, body: body, delivery: delivery})
    else
      {:error, :invalid}
    end
  end

  @doc """
  Claims the oldest unclaimed message, or `:empty`.

  A blank `task` takes the next message for any task, which is what firstmate
  polling the shared inbox wants.
  """
  def next(actor, task) do
    opts = Tenancy.opts(actor)

    transaction(fn ->
      InboxMessage
      |> Ash.Query.for_read(:claimable, %{task: presence(task)}, opts)
      |> Ash.read_one(opts)
      |> case do
        {:ok, nil} -> {:empty, []}
        {:ok, message} -> notifying(InboxMessage.claim(message, %{}, notify(opts)))
        {:error, error} -> {{:error, error}, []}
      end
    end)
    |> case do
      {:ok, %InboxMessage{} = claimed} -> {:ok, published(actor, claimed)}
      other -> other
    end
  end

  @doc "Confirms a claimed message by the ack token `next` returned."
  def ack(actor, token) do
    opts = Tenancy.opts(actor)

    with token when is_binary(token) <- presence(token),
         {:ok, message} when not is_nil(message) <- InboxMessage.get_by_ack(token, opts),
         {:ok, acked} <- InboxMessage.ack(message, %{}, opts) do
      {:ok, published(actor, acked)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Everything still outstanding, oldest first."
  def list(actor, task \\ nil) do
    read(actor, :open, task)
  end

  @doc "Newest messages for the portal, acked ones included."
  def recent(actor, task \\ nil) do
    read(actor, :recent, task)
  end

  def waiting_count(actor) do
    opts = Tenancy.opts(actor)

    InboxMessage
    |> Ash.Query.for_read(:open, %{}, opts)
    |> Ash.count(opts)
  end

  @doc "The `fm-task-inbox.v1` payload for one message."
  def wire(%InboxMessage{} = message) do
    %{
      "schema" => @schema,
      "at" => DateTime.to_iso8601(message.inserted_at),
      "task" => message.task,
      "seq" => message.seq,
      "body" => message.body,
      "delivery" => message.delivery,
      "sender" => message.sender,
      "claimed_by" => message.claimed_by,
      "status" => Atom.to_string(message.status),
      "ack" => message.id,
      "tenant" => message.tenant_slug
    }
  end

  defp read(actor, action, task) do
    opts = Tenancy.opts(actor)

    InboxMessage
    |> Ash.Query.for_read(action, %{task: presence(task)}, opts)
    |> Ash.read(opts)
    |> case do
      {:ok, messages} -> {:ok, Enum.map(messages, &wire/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp insert(actor, attrs) do
    opts = Tenancy.opts(actor)
    tenant = Tenancy.slug(actor)

    transaction(fn ->
      # Held to the end of the transaction, so the gap between reading the
      # highest seq and writing seq + 1 is not one another writer for this
      # tenant can slip into. Other tenants never wait on it.
      lock_tenant!(tenant)
      notifying(InboxMessage.put(Map.put(attrs, :seq, next_seq(tenant)), notify(opts)))
    end)
    |> case do
      {:ok, %InboxMessage{} = message} ->
        _ = fanout(message)
        {:ok, published(actor, message)}

      other ->
        other
    end
  end

  defp published(actor, %InboxMessage{} = message) do
    payload = wire(message)
    Phoenix.PubSub.broadcast(@pubsub, topic(actor), {:inbox_message, payload})
    payload
  end

  # Off the request path on purpose. Creating a stream is a JetStream round trip
  # with no deadline of its own, and the inbox this replaced made that call
  # inline in a single GenServer: one request that never came back wedged the
  # whole tenant's queue until the node was restarted. The row is already
  # committed by the time we get here, so a JetStream that is slow or down costs
  # the fan-out and nothing else.
  defp fanout(%InboxMessage{} = message) do
    Task.Supervisor.start_child(FirstmatePort.TaskSupervisor, fn ->
      publish_to_jetstream(message)
    end)
  end

  defp publish_to_jetstream(%InboxMessage{} = message) do
    subject = message.tenant_slug <> ".steer.inbox"

    case FirstmatePort.NATS.Connection.get() do
      {:ok, conn} ->
        _ = FirstmatePort.NATS.JetstreamConsumer.ensure_owned_streams(conn, message.tenant_slug)
        FirstmatePort.NATS.Connection.publish(subject, Jason.encode!(wire(message)))

      _ ->
        :ok
    end
  end

  defp next_seq(tenant) do
    %{rows: [[seq]]} =
      FirstmatePort.Repo.query!(
        "SELECT coalesce(max(seq), 0) + 1 FROM inbox_messages WHERE tenant_slug = $1",
        [tenant]
      )

    seq
  end

  defp lock_tenant!(tenant) do
    <<hi::signed-32, lo::signed-32, _rest::binary>> = :crypto.hash(:sha256, tenant)
    FirstmatePort.Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [hi, lo])
  end

  # An Ash write inside a transaction we opened ourselves cannot send its own
  # notifications: the rows are not committed yet. We carry them out and send
  # them once the transaction has closed.
  defp transaction(fun) do
    case FirstmatePort.Repo.transaction(fun) do
      {:ok, {result, notifications}} ->
        _ = Ash.Notifier.notify(notifications)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify(opts), do: Keyword.put(opts, :return_notifications?, true)

  defp notifying({:ok, record, notifications}), do: {{:ok, record}, notifications}
  defp notifying(other), do: {other, []}

  defp fetch(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
