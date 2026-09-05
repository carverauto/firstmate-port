defmodule FirstmatePortWeb.Plugs.RequireActor do
  @moduledoc """
  Requires any authenticated actor: a human (OIDC session or user JWT,
  which is what fm-steer carries) or an agent service token. Used by the
  portal-owned APIs (usage, routing) that both humans and agents call.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()

      _user ->
        conn
    end
  end
end
