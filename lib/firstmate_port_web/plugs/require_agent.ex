defmodule FirstmatePortWeb.Plugs.RequireAgent do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{role: :agent} ->
        conn

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "agent credential required"})
        |> halt()
    end
  end
end
