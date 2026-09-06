defmodule FirstmatePortWeb.SearchLiveTest do
  use FirstmatePortWeb.ConnCase, async: true

  import FirstmatePort.FleetFixtures
  import Phoenix.LiveViewTest

  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Fleet.Sync

  setup %{conn: conn} do
    tenant("local")
    robot = agent("local")
    person = human("local")

    {:ok, conn: sign_in(conn, person), robot: robot}
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:guardian_token, token)
  end

  test "an empty page asks for a query and says embeddings are off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")
    html = render_async(view)

    assert html =~ "Search the fleet log"
    assert html =~ "Type something to search"
    assert html =~ "Choose an embedding model"
  end

  test "searching finds a record and puts the query in the URL", %{conn: conn, robot: robot} do
    progress_item(robot, %{title: "BuildBuddy invocation vanished"})
    {:ok, _} = Sync.run("local")

    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> form("form[phx-submit=search]", %{"q" => "buildbuddy"})
    |> render_submit()

    html = render_async(view)

    assert html =~ "BuildBuddy invocation vanished"
    assert html =~ "words"
    assert_patched(view, ~p"/search?q=buildbuddy")
  end

  test "a query that matches nothing says why it might not be there yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> form("form[phx-submit=search]", %{"q" => "nothing-here"})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Nothing matched"
    assert html =~ "next fleet sync"
  end

  test "a query in the URL is answered on load", %{conn: conn, robot: robot} do
    progress_item(robot, %{title: "helm revision rolled back"})
    {:ok, _} = Sync.run("local")

    conn = get(conn, ~p"/search?q=helm")
    refute html_response(conn, 200) =~ "helm revision rolled back"
    assert html_response(conn, 200) =~ "Searching"
    {:ok, view, _html} = live(conn)
    html = render_async(view)

    assert html =~ "helm revision rolled back"
  end

  test "one tenant's search never shows another's log", %{conn: conn} do
    tenant("other")
    other = agent("other")
    progress_item(other, %{title: "other tenant secret"})
    {:ok, _} = Sync.run("other")

    {:ok, view, _html} = live(conn, ~p"/search?q=secret")
    html = render_async(view)

    refute html =~ "other tenant secret"
    assert html =~ "Nothing matched"
  end
end
