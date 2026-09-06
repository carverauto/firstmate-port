defmodule FirstmatePort.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "production reads the mounted BuildBuddy secret and independent tracking switches", %{
    tmp_dir: dir
  } do
    values = %{
      "DATABASE_URL" => "ecto://test:test@localhost/test",
      "SECRET_KEY_BASE" => String.duplicate("x", 64),
      "KUBERNETES_TRACKING_ENABLED" => "true",
      "DOCKER_TRACKING_ENABLED" => "false",
      "BUILDBUDDY_ORG_API_KEY" => "synthetic-env-key",
      "BUILDBUDDY_ORG_API_KEY_FILE" => Path.join(dir, "org-key")
    }

    original = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      for {key, value} <- original do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    File.write!(values["BUILDBUDDY_ORG_API_KEY_FILE"], "synthetic-file-key\n")
    System.put_env(values)
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    tracking = config[:firstmate_port][:build_tracking]
    assert tracking[:kubernetes_enabled] == true
    assert tracking[:docker_enabled] == false
    assert tracking[:buildbuddy_api_key] == "synthetic-file-key"
  end
end
