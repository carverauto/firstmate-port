defmodule FirstmatePortWeb.Api.FleetControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Fleet.Sync

  setup do
    tenant("local")
    {robot, token} = agent_with_token("local")
    {:ok, robot: robot, token: token}
  end

  defp as_agent(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "an agent searches the fleet log", %{conn: conn, token: token, robot: robot} do
    progress_item(robot, %{
      title: "BuildBuddy invocation vanished",
      url: "https://github.com/example/app/pull/42"
    })

    {:ok, _} = Sync.run("local")

    conn = conn |> as_agent(token) |> get(~p"/api/fleet/search", %{"q" => "buildbuddy"})

    assert %{"query" => "buildbuddy", "semantic" => %{"state" => "off"}, "data" => [hit]} =
             json_response(conn, 200)

    assert %{
             "source" => "progress_item",
             "title" => "BuildBuddy invocation vanished",
             "url" => "https://github.com/example/app/pull/42",
             "lexical_rank" => 1,
             "semantic_rank" => nil
           } = hit

    assert hit["score"] > 0
    assert %{"kind" => "note"} = hit["document"]
  end

  test "a response never carries a vector", %{conn: conn, token: token, robot: robot} do
    progress_item(robot, %{title: "roll five"})
    {:ok, _} = Sync.run("local")

    conn = conn |> as_agent(token) |> get(~p"/api/fleet/search", %{"q" => "roll"})

    assert %{"data" => [hit]} = json_response(conn, 200)
    refute Map.has_key?(hit, "embedding")
    refute Map.has_key?(hit, "search_text")
  end

  test "limit is bounded", %{conn: conn, token: token, robot: robot} do
    for index <- 1..3, do: progress_item(robot, %{title: "roll #{index}"})
    {:ok, _} = Sync.run("local")

    conn = conn |> as_agent(token) |> get(~p"/api/fleet/search", %{"q" => "roll", "limit" => "2"})

    assert %{"data" => [_one, _two]} = json_response(conn, 200)
  end

  test "an anonymous request cannot search", %{conn: conn, robot: robot} do
    progress_item(robot, %{title: "roll six"})
    {:ok, _} = Sync.run("local")

    conn = get(conn, ~p"/api/fleet/search", %{"q" => "roll"})

    assert json_response(conn, 403)
  end

  test "an agent can ask for a sync now", %{conn: conn, token: token, robot: robot} do
    progress_item(robot, %{title: "roll seven"})

    conn = conn |> as_agent(token) |> post(~p"/api/fleet/sync")

    assert %{"scanned" => 1, "written" => 1, "removed" => 0} = json_response(conn, 200)
  end

  test "an anonymous request cannot ask for a sync", %{conn: conn} do
    conn = post(conn, ~p"/api/fleet/sync")
    assert conn.status in [401, 403]
  end
  test "the query alias is ignored", %{conn: conn, token: token, robot: robot} do
    progress_item(robot, %{title: "roll"})
    {:ok, _} = Sync.run("local")

    conn = conn |> as_agent(token) |> get(~p"/api/fleet/search", %{"query" => "roll"})
    assert %{"query" => "", "data" => []} = json_response(conn, 200)
  end

  test "the maximum limit returns all one hundred matches", %{conn: conn, token: token, robot: robot} do
    titles = for index <- 1..100, do: "roll number #{index}"
    for title <- titles, do: progress_item(robot, %{title: title})
    {:ok, _} = Sync.run("local")

    conn = conn |> as_agent(token) |> get(~p"/api/fleet/search", %{"q" => "roll", "limit" => "100"})
    assert %{"data" => hits} = json_response(conn, 200)
    assert Enum.sort(Enum.map(hits, & &1["title"])) == Enum.sort(titles)
  end

end
