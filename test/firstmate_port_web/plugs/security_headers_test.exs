defmodule FirstmatePortWeb.Plugs.SecurityHeadersTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePortWeb.Plugs.SecurityHeaders

  defp reported(conn),
    do: List.first(get_resp_header(conn, "content-security-policy-report-only"))

  defp enforced(conn), do: List.first(get_resp_header(conn, "content-security-policy"))

  describe "browser responses" do
    test "carry a permissions policy", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert [policy] = get_resp_header(conn, "permissions-policy")
      assert policy =~ "camera=()"
      assert policy =~ "microphone=()"
      assert policy =~ "geolocation=()"
    end

    test "put the resource directives in report-only by default", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert policy = reported(conn)
      assert policy =~ "default-src 'self'"
      # LiveView needs its socket.
      assert policy =~ "connect-src 'self' ws: wss:"
    end

    test "still enforce the framing baseline while the rest is only reported", %{conn: conn} do
      # Browsers ignore frame-ancestors in a report-only policy, and Phoenix's
      # own put_secure_browser_headers enforces one. Report-only must not be a
      # downgrade from that.
      conn = get(conn, ~p"/login")

      assert policy = enforced(conn)
      assert policy =~ "frame-ancestors 'none'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "form-action 'self'"
      assert policy =~ "base-uri 'self'"
      # The part that could break a page is not enforced yet.
      refute policy =~ "default-src"
    end

    test "nonce the inline theme script instead of allowing all inline script", %{conn: conn} do
      conn = get(conn, ~p"/login")
      body = html_response(conn, 200)

      policy = reported(conn)
      refute policy =~ "'unsafe-inline' 'nonce"
      assert [_, nonce] = Regex.run(~r/script-src [^;]*'nonce-([^']+)'/, policy)
      assert body =~ "<script nonce=\"#{nonce}\">"
    end

    test "give each request its own nonce" do
      nonce_of = fn ->
        policy = build_conn() |> get(~p"/login") |> reported()
        [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
        nonce
      end

      refute nonce_of.() == nonce_of.()
    end

    test "switch to enforcing the whole policy when configured to", %{conn: conn} do
      put_env(SecurityHeaders, csp_mode: :enforce)

      conn = get(conn, ~p"/login")

      assert policy = enforced(conn)
      assert policy =~ "default-src 'self'"
      assert policy =~ "frame-ancestors 'none'"
      assert is_nil(reported(conn))
    end

    test "append a report URI when one is configured", %{conn: conn} do
      put_env(SecurityHeaders, csp_report_uri: "https://csp.example.com/report")

      assert conn |> get(~p"/login") |> reported() =~ "report-uri https://csp.example.com/report"
    end
  end

  describe "the public legal pages" do
    test "set no cookie, so a shared cache can hold them", %{conn: conn} do
      conn = get(conn, ~p"/terms")

      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      assert get_resp_header(conn, "set-cookie") == []
      assert enforced(conn) =~ "frame-ancestors 'none'"
    end
  end

  describe "stored diagram HTML" do
    test "gets a policy that allows its own inline script but nothing off-origin" do
      conn =
        :get
        |> Plug.Test.conn("/d/whatever")
        |> SecurityHeaders.call(SecurityHeaders.init(csp: :embed))
        |> Plug.Conn.send_resp(200, "")

      policy = reported(conn)
      assert policy =~ "script-src 'self' 'unsafe-inline' blob:"
      assert policy =~ "connect-src 'self'"
      # Framing and form posts stay blocked outright, not merely reported.
      assert enforced(conn) =~ "frame-ancestors 'none'"
      assert enforced(conn) =~ "form-action 'none'"
    end
  end

  describe "JSON responses" do
    test "get an enforced policy that permits nothing", %{conn: conn} do
      # Nothing to soak: a JSON body has no subresources a strict policy could
      # break, so this one is enforced from the start.
      conn = get(conn, ~p"/api/diagrams")

      assert policy = enforced(conn)
      assert policy =~ "default-src 'none'"
      assert is_nil(reported(conn))
    end
  end

  describe "HSTS" do
    # HSTS over plain HTTP is meaningless and browsers ignore it, so the plug
    # only sends it on HTTPS. Tests speak HTTP, hence the scheme override.
    test "is omitted on plain HTTP", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert get_resp_header(conn, "strict-transport-security") == []
    end

    test "is sent on HTTPS with a two-year max-age and subdomains" do
      conn =
        :get
        |> Plug.Test.conn("/login")
        |> Map.put(:scheme, :https)
        |> SecurityHeaders.call(SecurityHeaders.init(csp: :browser))
        |> Plug.Conn.send_resp(200, "")

      assert ["max-age=63072000; includeSubDomains"] =
               get_resp_header(conn, "strict-transport-security")
    end

    test "adds preload only when asked" do
      conn =
        :get
        |> Plug.Test.conn("/login")
        |> Map.put(:scheme, :https)
        |> SecurityHeaders.call(SecurityHeaders.init(csp: :browser, hsts_preload: true))
        |> Plug.Conn.send_resp(200, "")

      assert ["max-age=63072000; includeSubDomains; preload"] =
               get_resp_header(conn, "strict-transport-security")
    end
  end

  describe "init/1" do
    test "rejects an unknown CSP preset" do
      assert_raise ArgumentError, ~r/:csp must be/, fn ->
        SecurityHeaders.init(csp: :nonsense)
      end
    end
  end

  describe "nonce/1" do
    test "is nil on assigns from a conn that never ran the plug" do
      assert SecurityHeaders.nonce(%{}) == nil
    end
  end
end
