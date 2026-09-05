defmodule FirstmatePortWeb.CliAuthController do
  @moduledoc "RFC 8628 device-code endpoints for firstmatectl."
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.DeviceCode
  alias FirstmatePort.Auth.Guardian

  def device(conn, _params) do
    case DeviceCode.issue(%{}, authorize?: false) do
      {:ok, code} ->
        public = Application.get_env(:firstmate_port, :public_url, "http://localhost:4000")
        uri = String.trim_trailing(public, "/") <> "/login/device"

        json(conn, %{
          device_code: code.device_code,
          user_code: code.user_code,
          verification_uri: uri,
          verification_uri_complete: uri <> "?user_code=" <> code.user_code,
          expires_in: 600,
          interval: code.interval
        })

      {:error, error} ->
        conn |> put_status(:internal_server_error) |> json(%{error: inspect(error)})
    end
  end

  def token(conn, params) do
    device_code = params["device_code"]

    with true <- params["grant_type"] in [nil, "urn:ietf:params:oauth:grant-type:device_code"],
         {:ok, code} <- DeviceCode.get_by_device(device_code, authorize?: false) do
      cond do
        DateTime.compare(DateTime.utc_now(), code.expires_at) == :gt ->
          conn |> put_status(:bad_request) |> json(%{error: "expired_token"})

        code.status == :pending ->
          conn |> put_status(:bad_request) |> json(%{error: "authorization_pending"})

        code.status == :denied ->
          conn |> put_status(:bad_request) |> json(%{error: "access_denied"})

        code.status == :approved ->
          issue_cli_jwt(conn, code)
      end
    else
      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_grant"})
    end
  end

  defp issue_cli_jwt(conn, code) do
    case User.get(code.user_id, authorize?: false) do
      {:ok, user} ->
        claims = %{"typ" => "cli", "tenant" => code.tenant_slug || user.tenant_slug}

        case Guardian.encode_and_sign(user, claims) do
          {:ok, token, _} ->
            json(conn, %{
              access_token: token,
              token_type: "Bearer",
              expires_in: 12 * 3600,
              tenant: user.tenant_slug
            })

          {:error, reason} ->
            conn |> put_status(:internal_server_error) |> json(%{error: inspect(reason)})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_grant"})
    end
  end
end
