defmodule FirstmatePortWeb.BuildTrackingSurfaceTest do
  use FirstmatePortWeb.ConnCase, async: false

  test "Fleet log exposes only the opted-in environments", %{conn: conn} do
    original = Application.get_env(:firstmate_port, :build_tracking, [])
    on_exit(fn -> Application.put_env(:firstmate_port, :build_tracking, original) end)

    {:ok, human} =
      FirstmatePort.Accounts.User.upsert_oidc(
        %{email: "tracking-review@localhost", name: "Tracking reviewer"},
        authorize?: false
      )

    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human)

    for {name, config, visible} <- [
          {"default", [], []},
          {"kubernetes", [kubernetes_enabled: true], ["Kubernetes"]},
          {"docker", [docker_enabled: true], ["Docker"]},
          {"buildbuddy", [buildbuddy_api_key: "synthetic-test-key"], ["BuildBuddy"]}
        ] do
      Application.put_env(:firstmate_port, :build_tracking, config)

      html =
        conn |> init_test_session(%{"guardian_token" => jwt}) |> get("/") |> html_response(200)

      assert html =~ "Fleet log"
      refute html =~ "Farm / demo rolls"
      refute html =~ "No image builds or helm rolls recorded."

      for label <- ["Kubernetes", "Docker", "BuildBuddy"] do
        if label in visible, do: assert(html =~ label), else: refute(html =~ label)
      end

      if dir = System.get_env("TRACKING_TEST_EVIDENCE_DIR") do
        File.write!(Path.join(dir, "fleet-#{name}.html"), html)
      end
    end
  end
end
