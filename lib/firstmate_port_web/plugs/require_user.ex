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
          |> put_session(:return_to, return_to(conn))
          |> redirect(to: "/login")
          |> halt()
        end

      _user ->
        conn
    end
  end

  # The device-approval URL carries its code in the query string
  # (`/login/device?user_code=...`), so the path alone is not enough to get
  # the visitor back to approving after sign-in. Stays a relative path, so the
  # post-login redirect cannot leave this host.
  defp return_to(%{request_path: path, query_string: ""}), do: path
  defp return_to(%{request_path: path, query_string: query}), do: path <> "?" <> query
end
