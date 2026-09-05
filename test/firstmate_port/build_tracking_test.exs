defmodule FirstmatePort.BuildTrackingTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.BuildTracking

  setup do
    original = Application.get_env(:firstmate_port, :build_tracking, [])

    on_exit(fn -> Application.put_env(:firstmate_port, :build_tracking, original) end)
    :ok
  end

  defp put(config) do
    Application.put_env(:firstmate_port, :build_tracking, config)
  end

  test "all plates hidden by default" do
    put(kubernetes_enabled: false, docker_enabled: false, buildbuddy_api_key: nil)

    refute BuildTracking.kubernetes_enabled?()
    refute BuildTracking.docker_enabled?()
    refute BuildTracking.buildbuddy_enabled?()
  end

  test "kubernetes and docker flags are independent" do
    put(kubernetes_enabled: true, docker_enabled: false, buildbuddy_api_key: nil)

    assert BuildTracking.kubernetes_enabled?()
    refute BuildTracking.docker_enabled?()
    refute BuildTracking.buildbuddy_enabled?()
  end

  test "buildbuddy is enabled by key presence, not by the other flags" do
    put(kubernetes_enabled: false, docker_enabled: false, buildbuddy_api_key: "org-key")

    assert BuildTracking.buildbuddy_enabled?()
    refute BuildTracking.kubernetes_enabled?()
  end

  test "blank buildbuddy key counts as absent" do
    put(buildbuddy_api_key: "")

    refute BuildTracking.buildbuddy_enabled?()
    assert BuildTracking.api_key() == nil
  end

  test "host passes through, blank counts as absent" do
    put(buildbuddy_host: "https://bb.example.com")
    assert BuildTracking.buildbuddy_host() == "https://bb.example.com"

    put(buildbuddy_host: "")
    assert BuildTracking.buildbuddy_host() == nil
  end
end
