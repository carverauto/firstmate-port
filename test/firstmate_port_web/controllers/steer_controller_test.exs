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

  test "every served doc page is the repo markdown, not a second copy", %{conn: conn} do
    for page <- FirstmatePortWeb.SteerDocs.index() do
      html = conn |> get(~p"/steer/docs/#{page.slug}") |> html_response(200)

      served =
        page.path
        |> File.read!()
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      assert html =~ served, "#{page.slug} does not serve #{page.path} verbatim"
    end
  end

  test "an unknown doc slug is a 404", %{conn: conn} do
    assert conn |> get("/steer/docs/nope") |> response(404)
  end
end
