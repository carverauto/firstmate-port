defmodule FirstmatePortWeb.Api.QueueController do
  @moduledoc """
  HTTP port for the Queues look-in. `fm-steer queue post` reports what firstmate
  handed to a crewmate; the portal records it and fans it out over JetStream.
  fm-steer never dials NATS itself.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Queues
  alias FirstmatePort.Queues.Entry
  alias FirstmatePort.Tenancy

  def index(conn, _params) do
    entries = conn |> tenant() |> Queues.list() |> Enum.map(&Entry.to_map/1)
    json(conn, %{data: entries})
  end

  def create(conn, params) do
    case Queues.record(tenant(conn), params) do
      {:ok, entry} ->
        json(conn, Entry.to_map(entry))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: Atom.to_string(reason)})
    end
  end

  defp tenant(conn), do: Tenancy.slug(conn.assigns.current_user)
end
