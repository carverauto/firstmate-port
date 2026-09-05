defmodule FirstmatePort.Events do
  @moduledoc "AshEvents domain for portal event sourcing."

  use Ash.Domain, otp_app: :firstmate_port

  resources do
    resource FirstmatePort.Events.EventLog
  end
end
