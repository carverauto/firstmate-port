defmodule FirstmatePortWeb.OAuthMetadataController do
  @moduledoc """
  RFC 8414 / RFC 9728 discovery for MCP.

  Endpoints are read from the provider's own discovery document. They are never
  built by appending a vendor's URL layout to the issuer: those paths differ per
  provider, and guessing them hands MCP clients a document that points nowhere.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Auth.OIDC

  def protected_resource(conn, _params) do
    body = %{
      resource: mcp_resource(conn),
      bearer_methods_supported: ["header"],
      scopes_supported: ["mcp"]
    }

    body =
      case OIDC.issuer() do
        nil -> body
        issuer -> Map.put(body, :authorization_servers, [issuer])
      end

    json(conn, body)
  end

  def authorization_server(conn, _params) do
    case OIDC.provider_configuration() do
      {:ok, provider} ->
        json(
          conn,
          drop_undefined(%{
            issuer: provider.issuer,
            authorization_endpoint: provider.authorization_endpoint,
            token_endpoint: provider.token_endpoint,
            grant_types_supported: provider.grant_types_supported,
            response_types_supported: provider.response_types_supported,
            code_challenge_methods_supported: provider.code_challenge_methods_supported,
            token_endpoint_auth_methods_supported: provider.token_endpoint_auth_methods_supported,
            scopes_supported: provider.scopes_supported
          })
        )

      :error ->
        # No provider, or one that has not loaded its document. Say so rather
        # than inventing endpoints a client would fail against later.
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "oidc_not_configured",
          error_description:
            "This portal has no OpenID Connect provider available. Set OIDC_ISSUER, " <>
              "OIDC_CLIENT_ID and OIDC_CLIENT_SECRET, or sign in locally."
        })
    end
  end

  # oidcc reports an omitted discovery field as :undefined. Emitting that would
  # advertise the atom's name as a value.
  defp drop_undefined(map) do
    Map.reject(map, fn {_key, value} -> value == :undefined end)
  end

  defp mcp_resource(conn) do
    public = Application.get_env(:firstmate_port, :public_url, url(conn, ~p"/"))
    String.trim_trailing(public, "/") <> "/mcp"
  end
end
