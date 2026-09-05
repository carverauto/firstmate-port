defmodule FirstmatePort.NATS.Supervisor do
  @moduledoc """
  Wraps Gnat.ConnectionSupervisor. Shape copied from ServiceRadar.NATS.Supervisor.
  """

  use Supervisor

  require Logger

  @backoff_period 5_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = FirstmatePort.NATS.Connection.config()

    if Keyword.get(config, :enabled, false) do
      connection_settings =
        %{
          host: Keyword.get(config, :host, "127.0.0.1"),
          port: Keyword.get(config, :port, 4222),
          name: "firstmate-port"
        }
        |> maybe_token(Keyword.get(config, :token))
        |> maybe_user(Keyword.get(config, :username), Keyword.get(config, :password))

      gnat_supervisor_settings = %{
        name: FirstmatePort.NATS.Connection.connection_name(),
        backoff_period: Keyword.get(config, :backoff_period, @backoff_period),
        connection_settings: [connection_settings]
      }

      children = [
        {Gnat.ConnectionSupervisor, gnat_supervisor_settings},
        FirstmatePort.NATS.QueueListener
      ]

      Logger.info("Starting NATS supervisor")
      Supervisor.init(children, strategy: :rest_for_one)
    else
      Logger.info("NATS disabled")
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  defp maybe_token(settings, token) when is_binary(token) and token != "" do
    Map.put(settings, :token, token)
  end

  defp maybe_token(settings, _), do: settings

  defp maybe_user(settings, user, pass)
       when is_binary(user) and user != "" and is_binary(pass) and pass != "" do
    settings
    |> Map.put(:username, user)
    |> Map.put(:password, pass)
  end

  defp maybe_user(settings, _, _), do: settings
end
