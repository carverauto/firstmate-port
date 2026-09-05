defmodule FirstmatePortWeb.SteerControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  test "landing page is public and states the pitch", %{conn: conn} do
    html = conn |> get(~p"/steer") |> html_response(200)

    assert html =~ "Send every task to the right worker"
    assert html =~ "fm-steer route"
    assert html =~ "fm-steer usage"
    refute html =~ "—"
    refute html =~ "–"
  end

  for path <- ["/steer/docs", "/steer/docs/fm-steer", "/steer/docs/routing", "/steer/docs/usage"] do
    test "GET #{path} is public", %{conn: conn} do
      html = conn |> get(unquote(path)) |> html_response(200)
      assert html =~ "Back to"
      refute html =~ "—"
    end
  end

  test "docs pages carry their content", %{conn: conn} do
    assert conn |> get(~p"/steer/docs/fm-steer") |> html_response(200) =~ "auth login"
    assert conn |> get(~p"/steer/docs/routing") |> html_response(200) =~ "blast_radius"
    assert conn |> get(~p"/steer/docs/usage") |> html_response(200) =~ "spend priority"
  end

  test "docs pages render real HTML, not markdown source", %{conn: conn} do
    routing = conn |> get(~p"/steer/docs/routing") |> html_response(200)

    assert routing =~ "<table>"
    assert routing =~ "<th>Axis</th>"
    assert routing =~ "<h2>Capability matrix</h2>"
    refute routing =~ "|---|"
    refute routing =~ "```"
    refute routing =~ "## Axes"
  end
end
