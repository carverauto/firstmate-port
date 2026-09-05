defmodule FirstmatePortWeb.LiveUser do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:require_user, _params, session, socket) do
    case session_user(session) do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user ->
        {:cont, assign(socket, current_user: user)}
    end
  end

  defp session_user(%{"guardian_token" => token}) do
    case FirstmatePort.Auth.Guardian.resource_from_token(token) do
      {:ok, user, _} -> user
      _ -> nil
    end
  end

  defp session_user(_), do: nil
end
