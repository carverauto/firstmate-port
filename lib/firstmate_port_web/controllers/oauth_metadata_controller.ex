defmodule FirstmatePortWeb.OAuthMetadataController do
  @moduledoc """
  RFC 8414 / RFC 9728 discovery for MCP. Shape copied from web-ng.
  """

  use FirstmatePortWeb, :controller

  def protected_resource(conn, _params) do
    json(conn, %{
      resource: mcp_resource(conn),
      authorization_servers: [issuer()],
      bearer_methods_supported: ["header"],
      scopes_supported: ["mcp"]
    })
  end

  def authorization_server(conn, _params) do
    iss = issuer()

    json(conn, %{
      issuer: iss,
      authorization_endpoint: iss <> "/application/o/authorize/",
      token_endpoint: iss <> "/application/o/token/",
      grant_types_supported: ["authorization_code", "client_credentials"],
      response_types_supported: ["code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["client_secret_post", "client_secret_basic"],
      scopes_supported: ["mcp", "openid", "email", "profile"]
    })
  end

  defp issuer do
    Application.get_env(:firstmate_port, :oidc_issuer) ||
      get_in(Application.get_env(:firstmate_port, FirstmatePortWeb.Auth.OIDCStrategy), [
        :issuer
      ]) ||
      ""
  end

  defp mcp_resource(conn) do
    public = Application.get_env(:firstmate_port, :public_url, url(conn, ~p"/"))
    String.trim_trailing(public, "/") <> "/mcp"
  end
end
