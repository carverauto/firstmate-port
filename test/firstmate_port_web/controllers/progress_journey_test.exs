defmodule FirstmatePortWeb.ProgressJourneyTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian

  test "agent HTTP events preserve history and appear in the captain's fleet log" do
    token = "progress-journey-#{System.unique_integer([:positive])}"

    {:ok, _agent} =
      User.bootstrap_agent(
        %{
          email: "#{token}@localhost",
          name: "First mate",
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, captain} =
      User.upsert_oidc(
        %{email: "captain-#{token}@localhost", name: "Captain"},
        authorize?: false
      )

    api = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> token) end

    created =
      api.()
      |> post("/api/progress", %{kind: "note", title: "Release preparation", status: "queued"})
      |> json_response(200)

    id = created["id"]

    working =
      api.()
      |> post("/api/progress/#{id}/events", %{
        status: "working",
        assignee: "firstmate",
        extra_workers: ["secondmate"]
      })
      |> json_response(200)

    done =
      api.()
      |> post("/api/progress/#{id}/events", %{
        status: "done",
        title: "Release ready",
        interruption: ""
      })
      |> json_response(200)

    assert working["id"] != done["id"]
    assert working["item_id"] == id
    assert done["item_id"] == id

    assert %{rows: [["Release preparation", "queued"]]} =
             initial =
             FirstmatePort.Repo.query!("SELECT title, status FROM progress_items WHERE id = $1", [
               id
             ])

    assert %{rows: [["working"], ["done"]]} =
             history =
             FirstmatePort.Repo.query!(
               "SELECT status FROM progress_events WHERE item_id = $1 ORDER BY seq",
               [id]
             )

    {:ok, browser_token, _} = Guardian.encode_and_sign(captain, %{})

    browser =
      build_conn() |> init_test_session(%{}) |> put_session(:guardian_token, browser_token)

    html = browser |> get("/?tab=progress") |> html_response(200)
    assert html =~ "Release ready"
    assert html =~ "done"
    assert html =~ "firstmate"
    assert html =~ "secondmate"
    refute html =~ "Release preparation"

    if dir = System.get_env("PROGRESS_JOURNEY_EVIDENCE") do
      File.write!(
        Path.join(dir, "progress-api-journey.json"),
        Jason.encode!(
          %{
            create_response: created,
            working_event_response: working,
            done_event_response: done,
            persisted_initial: initial.rows,
            persisted_event_statuses: history.rows,
            portal: "GET /?tab=progress: HTTP 200; Release ready, done, firstmate, secondmate"
          },
          pretty: true
        )
      )

      File.write!(Path.join(dir, "progress-projection.html"), html)
    end
  end
end
