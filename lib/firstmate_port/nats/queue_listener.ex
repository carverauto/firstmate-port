defmodule FirstmatePort.NATS.QueueListener do
  @moduledoc """
  Durable JetStream consumers for firstmate.steer.> and firstmate.discord.inbound.
  Broadcasts to PubSub for LiveView. Resubscribes when the Gnat pid dies.
  """

  use GenServer

  alias FirstmatePort.NATS.JetstreamConsumer

  require Logger

  @pubsub FirstmatePort.PubSub
  @topic "nats:queues"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{recent: [], conn_ref: nil}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    case FirstmatePort.NATS.Connection.get() do
      {:ok, conn} ->
        ref = Process.monitor(conn)

        _ = JetstreamConsumer.ensure_owned_streams(conn)

        _ =
          JetstreamConsumer.ensure_durable(conn,
            stream_name: JetstreamConsumer.steer_stream(),
            consumer_name: "firstmate-port-ui-steer",
            subjects: JetstreamConsumer.steer_subjects()
          )

        _ =
          JetstreamConsumer.ensure_durable(conn,
            stream_name: JetstreamConsumer.inbound_stream(),
            consumer_name: "firstmate-port-ui-discord",
            subjects: JetstreamConsumer.inbound_subjects()
          )

        {:ok, _} = Gnat.sub(conn, self(), "firstmate.steer.>")
        {:ok, _} = Gnat.sub(conn, self(), "firstmate.discord.inbound")
        {:noreply, %{state | conn_ref: ref}}

      {:error, reason} ->
        Logger.info("NATS listener waiting: #{inspect(reason)}")
        Process.send_after(self(), :retry, 5_000)
        {:noreply, %{state | conn_ref: nil}}
    end
  end

  @impl true
  def handle_info(:retry, state), do: {:noreply, state, {:continue, :subscribe}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    Logger.warning("NATS connection died (#{inspect(reason)}); resubscribing")
    Process.send_after(self(), :retry, 1_000)
    {:noreply, %{state | conn_ref: nil}}
  end

  def handle_info({:msg, %{body: body, topic: subject} = msg}, state) do
    event = %{
      subject: subject,
      body: truncate(body),
      at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:nats_event, event})
    _ = maybe_assign(subject, body)
    _ = ack(msg)
    recent = Enum.take([event | state.recent], 100)
    {:noreply, %{state | recent: recent}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  def topic, do: @topic

  defp ack(%{reply_to: reply}) when is_binary(reply) and reply != "" do
    case FirstmatePort.NATS.Connection.get() do
      {:ok, conn} -> Gnat.pub(conn, reply, "+ACK")
      _ -> :ok
    end
  end

  defp ack(_), do: :ok

  defp truncate(body) when is_binary(body) and byte_size(body) > 500,
    do: binary_part(body, 0, 500)

  defp truncate(body), do: body

  defp maybe_assign(subject, body) when is_binary(subject) and is_binary(body) do
    if String.starts_with?(subject, "firstmate.steer.") do
      case Jason.decode(body) do
        {:ok, map} -> FirstmatePort.Portal.Assignment.apply(map)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_assign(_, _), do: :ok
end
