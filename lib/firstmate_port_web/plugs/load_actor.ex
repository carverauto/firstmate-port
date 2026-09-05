defmodule FirstmatePortWeb.Plugs.LoadActor do
  @moduledoc "Loads OIDC session or agent API key into conn.assigns.current_user."

  import Plug.Conn

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      user = bearer_user(conn) ->
        assign(conn, :current_user, user)

      user = session_user(conn) ->
        assign(conn, :current_user, user)

      true ->
        assign(conn, :current_user, nil)
    end
  end

  defp bearer_user(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case User.authenticate_api_key(token, authorize?: false) do
          {:ok, user} ->
            user

          _ ->
            case Guardian.resource_from_token(token) do
              {:ok, user, _claims} -> user
              _ -> nil
            end
        end

      _ ->
        nil
    end
  end

  defp session_user(conn) do
    if conn.private[:plug_session_fetch] != :done do
      nil
    else
      case get_session(conn, :guardian_token) do
        token when is_binary(token) ->
          case Guardian.resource_from_token(token) do
            {:ok, user, _claims} -> user
            _ -> nil
          end

        _ ->
          nil
      end
    end
  end
end
