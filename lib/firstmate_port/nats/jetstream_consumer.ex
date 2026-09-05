defmodule FirstmatePort.NATS.JetstreamConsumer do
  @moduledoc """
  Shared helpers for durable JetStream consumers.
  Shape copied from ServiceRadar.NATS.JetstreamConsumer (ensure_durable).
  Firstmate subjects, not ServiceRadar subject names.

  Stream ownership is per tenant on one NATS account:
  * `<tenant>.steer` — subjects `<tenant>.steer.>` only
  * `<tenant>.inbound` — subject `<tenant>.discord.inbound` only

  The API must not create a `<tenant>.>` catch-all.
  """

  alias FirstmatePort.Tenancy
  alias Gnat.Jetstream.API.{Consumer, Stream}

  require Logger

  @spec ensure_owned_streams(atom() | pid(), String.t()) :: :ok | {:error, term()}
  def ensure_owned_streams(conn, tenant) when is_binary(tenant) do
    with :ok <- ensure_stream(conn, steer_stream(tenant), steer_subjects(tenant)),
         :ok <- ensure_stream(conn, inbound_stream(tenant), inbound_subjects(tenant)) do
      :ok
    end
  end

  @spec ensure_durable(atom() | pid(), keyword()) ::
          {:ok, %{stream_name: String.t(), consumer_name: String.t()}} | {:error, term()}
  def ensure_durable(connection_ref, opts) do
    stream_name = Keyword.fetch!(opts, :stream_name)
    consumer_name = Keyword.fetch!(opts, :consumer_name)
    subjects = Keyword.get(opts, :subjects) || subjects_for(stream_name)

    with :ok <- ensure_stream(connection_ref, stream_name, subjects),
         :ok <- ensure_consumer(connection_ref, stream_name, consumer_name, hd(subjects)) do
      {:ok, %{stream_name: stream_name, consumer_name: consumer_name}}
    end
  end

  defdelegate steer_stream(tenant), to: Tenancy
  defdelegate inbound_stream(tenant), to: Tenancy
  defdelegate steer_subjects(tenant), to: Tenancy
  defdelegate inbound_subjects(tenant), to: Tenancy

  defp subjects_for(name) do
    case String.split(name, ".", parts: 2) do
      [tenant, "steer"] -> steer_subjects(tenant)
      [tenant, "inbound"] -> inbound_subjects(tenant)
      _ -> []
    end
  end

  defp ensure_stream(conn, name, subjects) do
    case Stream.info(conn, name) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        cfg = %Stream{
          name: name,
          subjects: Enum.uniq(subjects),
          storage: :file,
          num_replicas: replicas()
        }

        case Stream.create(conn, cfg) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_consumer(conn, stream_name, consumer_name, filter) do
    case Consumer.info(conn, stream_name, consumer_name) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        config = %Consumer{
          stream_name: stream_name,
          durable_name: consumer_name,
          ack_policy: :explicit,
          filter_subject: filter,
          deliver_policy: :new
        }

        case Consumer.create(conn, config) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp replicas do
    Application.get_env(:firstmate_port, FirstmatePort.NATS.Connection, [])
    |> Keyword.get(:replicas, 3)
  end
end
