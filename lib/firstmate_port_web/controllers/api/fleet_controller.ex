defmodule FirstmatePortWeb.Api.FleetController do
  @moduledoc """
  Searching the fleet log, and asking for a sync now rather than on the tick.

  `fm-steer` reads this; the portal's own search page calls
  `FirstmatePort.Fleet.Search` directly. Both are the one Elixir path, so
  there is nothing to keep in step.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Fleet.{Search, Sync}
  alias FirstmatePort.Tenancy

  @max_limit 100

  def search(conn, params) do
    actor = conn.assigns.current_user
    query = params["q"] || ""

    case Search.run(query, actor, limit: limit(params)) do
      {:ok, result} ->
        json(conn, Search.response(result))

      {:error, error} ->
        # The only way a search fails is authorization, same as the list
        # endpoints beside it.
        conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  def sync(conn, _params) do
    case Sync.run(Tenancy.slug(conn.assigns.current_user)) do
      {:ok, summary} ->
        json(conn, summary)

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  defp limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {value, _rest} when value > 0 -> min(value, @max_limit)
      _ -> 25
    end
  end
end
