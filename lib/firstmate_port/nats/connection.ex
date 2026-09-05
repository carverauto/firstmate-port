defmodule FirstmatePort.NATS.Connection do
  @moduledoc """
  NATS connection API. Shape copied from ServiceRadar.NATS.Connection
  (Gnat.ConnectionSupervisor, not a raw Gnat.start_link).
  """

  require Logger

  @connection_name :firstmate_nats

  @spec get() :: {:ok, pid()} | {:error, term()}
  def get do
    case Process.whereis(connection_name()) do
      nil ->
        {:error, :not_connected}

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :connection_dead}
    end
  end

  @spec publish(String.t(), String.t() | binary()) :: :ok | {:error, term()}
  def publish(subject, payload) do
    case get() do
      {:ok, conn} ->
        try do
          Gnat.pub(conn, subject, payload)
        catch
          :exit, reason ->
            Logger.warning("NATS publish failed: #{inspect(reason)}")
            {:error, {:nats_connection_died, reason}}
        end

      {:error, reason} ->
        {:error, {:nats_not_connected, reason}}
    end
  end

  @spec connected?() :: boolean()
  def connected? do
    match?({:ok, _}, get())
  end

  def connection_name do
    config() |> Keyword.get(:name, @connection_name)
  end

  def config do
    Application.get_env(:firstmate_port, __MODULE__, [])
  end
end
