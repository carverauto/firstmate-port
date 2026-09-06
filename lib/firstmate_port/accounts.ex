defmodule FirstmatePort.Accounts do
  @moduledoc """
  Humans (OIDC or local sign-in) and agent service credentials.
  """

  use Ash.Domain,
    otp_app: :firstmate_port,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource FirstmatePort.Accounts.Tenant
    resource FirstmatePort.Accounts.User
    resource FirstmatePort.Auth.DeviceCode
    resource FirstmatePort.Auth.CliSession
  end
end
