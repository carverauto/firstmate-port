defmodule FirstmatePort.Validations.TrackingEnabled do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(_changeset, opts, _context) do
    enabled? =
      case Keyword.fetch!(opts, :track) do
        :kubernetes -> FirstmatePort.BuildTracking.kubernetes_enabled?()
        :docker -> FirstmatePort.BuildTracking.docker_enabled?()
        :buildbuddy -> FirstmatePort.BuildTracking.buildbuddy_enabled?()
      end

    if enabled?, do: :ok, else: {:error, message: "tracking is disabled"}
  end
end
