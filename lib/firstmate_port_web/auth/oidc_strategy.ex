defmodule FirstmatePortWeb.Auth.OIDCStrategy do
  @moduledoc """
  Authentik OIDC config from application env.
  Ueberauth.Strategy.Oidcc verifies ID token iss/aud/sig via Oidcc/JWKS.
  """

  def enabled? do
    cfg = config()
    is_binary(cfg[:client_id]) and cfg[:client_id] != "" and is_binary(cfg[:discovery_url])
  end

  def config do
    Application.get_env(:firstmate_port, __MODULE__, [])
  end

  def discovery_url, do: Keyword.get(config(), :discovery_url)

  def scopes, do: Keyword.get(config(), :scopes, ["openid", "email", "profile"])

  def redirect_uri, do: Keyword.get(config(), :redirect_uri)

  def client_id, do: Keyword.get(config(), :client_id)

  def client_secret, do: Keyword.get(config(), :client_secret)

  def issuer do
    Keyword.get(config(), :issuer) ||
      discovery_url()
      |> to_string()
      |> String.replace_suffix("/.well-known/openid-configuration", "/")
  end
end
