defmodule FirstmatePortWeb.LegalControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  describe "public reachability" do
    # This is the whole point of the pages: Discord's Developer Portal fetches
    # both URLs signed out, and a redirect to /login fails that check.
    test "GET /terms answers 200 without a session", %{conn: conn} do
      conn = get(conn, ~p"/terms")
      assert html_response(conn, 200) =~ "Terms of Service"
    end

    test "GET /privacy answers 200 without a session", %{conn: conn} do
      conn = get(conn, ~p"/privacy")
      assert html_response(conn, 200) =~ "Privacy Policy"
    end

    test "both are cacheable so a crawl burst does not reach Phoenix twice" do
      for path <- [~p"/terms", ~p"/privacy"] do
        conn = get(build_conn(), path)
        assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      end
    end
  end

  describe "content" do
    test "the terms cover the things the portal actually does", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)

      assert body =~ "password-based local"
      assert body =~ "optional extra restriction"
      assert body =~ "Acceptable use"
      assert body =~ "Integration credentials"
      assert body =~ "Discord"
      assert body =~ "Last updated"
    end

    test "the privacy policy names what is collected and for how long", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)

      assert body =~ "password hash"
      assert body =~ "24 hours"
      assert body =~ "five-minute cleanup interval"
      assert body =~ "configured counting window"
      assert body =~ "Your account"
      assert body =~ "Security signals"
      assert body =~ "Discord interactions"
      assert body =~ "How long it is kept"
      assert body =~ "Last updated"
    end

    test "each page links to the other so a reader can get between them", %{conn: conn} do
      assert conn |> get(~p"/terms") |> html_response(200) =~ ~s(href="/privacy")
      assert conn |> get(~p"/privacy") |> html_response(200) =~ ~s(href="/terms")
    end
  end

  describe "operator identity" do
    test "a configured operator and contact appear on both pages" do
      put_env(:legal, operator: "Example Ltd", contact_email: "privacy@example.com")

      for path <- [~p"/terms", ~p"/privacy"] do
        body = build_conn() |> get(path) |> html_response(200)
        assert body =~ "Example Ltd"
        assert body =~ "mailto:privacy@example.com"
      end
    end

    test "with no contact configured the page says so rather than inventing one", %{conn: conn} do
      put_env(:legal, operator: nil, contact_email: nil)

      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "has not published a contact address"
      refute body =~ "mailto:"
    end

    test "the governing law clause is omitted when unset", %{conn: conn} do
      put_env(:legal, governing_law: nil)
      refute conn |> get(~p"/terms") |> html_response(200) =~ "Governing law"

      put_env(:legal, governing_law: "England and Wales")
      body = build_conn() |> get(~p"/terms") |> html_response(200)
      assert body =~ "Governing law"
      assert body =~ "England and Wales"
    end
  end

  describe "discoverability" do
    test "the sign-in page carries both links", %{conn: conn} do
      body = conn |> get(~p"/login") |> html_response(200)

      assert body =~ ~s(href="/terms")
      assert body =~ ~s(href="/privacy")
    end
  end
end

