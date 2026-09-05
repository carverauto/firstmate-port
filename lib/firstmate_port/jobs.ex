defmodule FirstmatePort.Jobs do
  @moduledoc "AshOban scheduled work. Does not include the Mac Bazel cache wipe."

  use Ash.Domain, otp_app: :firstmate_port

  resources do
    resource FirstmatePort.Jobs.Tick
  end
end
