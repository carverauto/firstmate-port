defmodule FirstmatePort.Auth.Guardian do
  @moduledoc """
  Guardian JWT for browser sessions and agent API tokens.
  Shape copied from ServiceRadarWebNG.Auth.Guardian (no AshAuthentication tokens).
  """

  use Guardian, otp_app: :firstmate_port

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.CliSession

  @impl Guardian
  def subject_for_token(%User{id: id}, _claims), do: {:ok, "user:#{id}"}
  def subject_for_token(_, _), do: {:error, :invalid_resource}

  @impl Guardian
  def resource_from_claims(%{"sub" => "user:" <> id}) do
    User.get(id, authorize?: false)
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}

  @doc """
  Rejects a `fm-steer` token whose session was revoked in the portal.

  Signature and expiry alone cannot express "the captain ended that session", so
  every CLI token is checked against `FirstmatePort.Auth.CliSession` here - the
  one place every decode goes through. Browser and agent tokens are not
  session-backed and pass straight through.
  """
  @impl Guardian
  def verify_claims(%{"typ" => "cli"} = claims, _opts) do
    if CliSession.active?(claims["jti"]) do
      {:ok, claims}
    else
      {:error, :session_revoked}
    end
  end

  def verify_claims(claims, _opts), do: {:ok, claims}
end
