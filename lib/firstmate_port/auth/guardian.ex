defmodule FirstmatePort.Auth.Guardian do
  @moduledoc """
  Guardian JWT for browser sessions and agent API tokens.
  Shape copied from ServiceRadarWebNG.Auth.Guardian (no AshAuthentication tokens).
  """

  use Guardian, otp_app: :firstmate_port

  alias FirstmatePort.Accounts.User

  @impl Guardian
  def subject_for_token(%User{id: id}, _claims), do: {:ok, "user:#{id}"}
  def subject_for_token(_, _), do: {:error, :invalid_resource}

  @impl Guardian
  def resource_from_claims(%{"sub" => "user:" <> id}) do
    User.get(id, authorize?: false)
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}
end
