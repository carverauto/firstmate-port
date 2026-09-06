defmodule FirstmatePortWeb.DiagramHTMLControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Portal.Diagram
  alias FirstmatePort.Tenancy

  for mode <- [:report_only, :enforce] do
    @tag csp_mode: mode
    test "uploaded HTML is sandboxed and unchanged in #{mode} mode", %{conn: conn, csp_mode: mode} do
      FirstmatePort.Test.AppConfig.put_env(FirstmatePortWeb.Plugs.SecurityHeaders, csp_mode: mode)

      {:ok, uploader} =
        User.upsert_oidc(
          %{email: "uploader-#{System.unique_integer([:positive])}@localhost", name: "Uploader"},
          authorize?: false
        )

      {:ok, viewer} =
        User.upsert_oidc(
          %{
            email: "viewer-#{System.unique_integer([:positive])}@localhost",
            name: "Viewer",
            tenant_slug: uploader.tenant_slug
          },
          authorize?: false
        )

      html = """
      <!doctype html><html><body>
      <svg viewBox="0 0 100 100"><circle id="node" cx="50" cy="50" r="10" /></svg>
      <button onclick="document.getElementById('node').setAttribute('r', '20')">Expand</button>
      <script>document.body.dataset.ready = 'true';</script>
      </body></html>
      """

      assert {:ok, diagram} =
               Diagram.upload(%{title: "Interactive diagram", html: html}, Tenancy.opts(uploader))

      {:ok, token, _} = Guardian.encode_and_sign(viewer, %{})

      conn =
        conn
        |> init_test_session(%{guardian_token: token})
        |> get("/d/#{diagram.id}")

      assert response(conn, 200) == html

      assert [policy] = get_resp_header(conn, "content-security-policy")
      directives = policy |> String.split(";") |> Enum.map(&String.split/1)
      assert ["sandbox", "allow-scripts"] in directives
      assert ["frame-ancestors", "'none'"] in directives

      if mode == :enforce do
        assert ["script-src", "'self'", "'unsafe-inline'", "blob:"] in directives
      end
    end
  end

  test "anonymous curl cannot fetch the OG card", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "curl/8.0")
      |> get("/d/does-not-exist/card.png")

    assert conn.status == 401
  end

  test "discord crawler is admitted to the card path", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0 (compatible; Discordbot/2.0)")
      |> get("/d/does-not-exist/card.png")

    assert conn.status == 404
  end
end
