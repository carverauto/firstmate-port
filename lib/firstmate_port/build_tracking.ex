defmodule FirstmatePort.BuildTracking do
  @moduledoc """
  Opt-in switches for build tracking plates.

  Kubernetes rolls, Docker builds, and BuildBuddy invocations are each
  independently optional. Absent config hides the plate/tab; the portal
  never renders an empty farm-rolls message. See `docs/build-tracking.md`.
  """

  @doc "True when Kubernetes roll tracking is opted in."
  def kubernetes_enabled?, do: flag?(:kubernetes_enabled)

  @doc "True when Docker build tracking is opted in."
  def docker_enabled?, do: flag?(:docker_enabled)

  @doc """
  True when BuildBuddy tracking is opted in, i.e. an org API key is
  present. The key arrives as a secret (`BUILDBUDDY_ORG_API_KEY`) and is
  never committed.
  """
  def buildbuddy_enabled?, do: api_key() not in [nil, ""]

  @doc "Configured BuildBuddy host (e.g. `https://app.buildbuddy.io`), if any."
  def buildbuddy_host do
    case Keyword.get(config(), :buildbuddy_host) do
      "" -> nil
      host -> host
    end
  end

  @doc "Configured BuildBuddy org API key, if any. Never log this value."
  def api_key do
    case Keyword.get(config(), :buildbuddy_api_key) do
      "" -> nil
      key -> key
    end
  end

  defp flag?(key), do: Keyword.get(config(), key, false) == true

  defp config, do: Application.get_env(:firstmate_port, :build_tracking, [])
end
