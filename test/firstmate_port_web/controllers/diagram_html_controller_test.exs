defmodule FirstmatePortWeb.DiagramHTMLControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

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
