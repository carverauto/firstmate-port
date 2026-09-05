defmodule FirstmatePortWeb.Plugs.RequireUser do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        if conn.private[:phoenix_format] == "json" or
             "application/json" in get_req_header(conn, "accept") do
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{error: "unauthorized"})
          |> halt()
        else
          conn
          |> put_session(:return_to, conn.request_path)
          |> redirect(to: "/login")
          |> halt()
        end

      _user ->
        conn
    end
  end
end
