defmodule FirstmatePortWeb.ProgressLiveTest do
  @moduledoc """
  The two progress surfaces: the capped home preview and the paginated
  `/progress` archive, plus the details view both of them open.
  """

  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Portal.ProgressItem

  setup %{conn: conn} do
    ctx = agent_context("progress-live")
    {:ok, conn: sign_in(conn, human("progress")), opts: ctx.opts, api_key: ctx.api_key}
  end

  defp sign_in(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:guardian_token, token)
  end

  test "assignment configuration appears in both detail sections", %{conn: conn, opts: opts} do
    item = seed_item(opts, title: "assigned work")

    append(
      item,
      %{
        type: :assignment,
        worker: "crew-config",
        runtime: "codex",
        model: "gpt-test",
        effort: "high"
      },
      opts
    )

    {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")
    assert html =~ "crew-config codex gpt-test high"
  end

  test "zero token contributions remain distinct from missing telemetry" do
    alias FirstmatePortWeb.ProgressComponents

    bars =
      ProgressComponents.contributor_bars(%{
        contributions: [
          %{worker: "measured", tokens: 0, role: :implement},
          %{worker: "unknown", tokens: nil, role: :implement}
        ]
      })

    assert Enum.find(bars, &(&1.label == "measured")).display == "0"
    assert Enum.find(bars, &(&1.label == "unknown")).display == "—"
  end

  test "both modals page through the complete event history", %{conn: conn, opts: opts} do
    item = seed_item(opts, title: "long history")
    for n <- 1..101, do: append(item, %{type: :note, detail: "history-entry-#{n}"}, opts)

    for path <- [~p"/?item=#{item.id}", ~p"/progress?item=#{item.id}"] do
      {:ok, view, html} = live(conn, path)
      refute html =~ "history-entry-101"
      assert view |> element("a", "Next events") |> render_click() =~ "history-entry-101"
      assert has_element?(view, "a", "Previous events")
    end
  end

  test "only a truly empty log receives the empty observation" do
    projection = FirstmatePort.Portal.ProgressProjection.project(%ProgressItem{kind: :pr}, [])

    assert [{"log", "Nothing appended yet, so there is nothing to observe."}] =
             FirstmatePortWeb.ProgressComponents.heuristics(projection)
  end

  test "active work renders unknown timeline duration and neutral observations", %{
    conn: conn,
    opts: opts
  } do
    item = seed_item(opts, kind: :pr, title: "active work")
    append(item, %{type: :status, status: :in_progress}, opts)
    {:ok, view, html} = live(conn, ~p"/progress?item=#{item.id}")
    assert html =~ "No additional observations."
    refute html =~ "Nothing appended yet"
    timeline = view |> element(".timeline-key") |> render()
    assert timeline =~ "—"
    refute timeline =~ "0ms"
  end

  describe "home preview" do
    test "links to progress even when there are no rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "a[href='/progress']")
    end

    test "shows the newest 10 with a see-all link", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ title(25)
      assert html =~ title(16)
      refute html =~ title(15)
      assert html =~ "See all 25"
      assert html =~ "/progress"
    end

    test "the progress tab filter stays capped", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/?tab=progress")

      assert html =~ title(25)
      refute html =~ title(15)
      assert html =~ "See all 25"
    end

    test "keeps the see-all link when the preview holds everything", %{conn: conn, opts: opts} do
      seed_items(opts, 10)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ title(1)
      assert html =~ "See all"
    end

    test "keeps its empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "No PRs, issues, or achievements recorded."
      assert html =~ "See all"
    end

    test "shows the compact columns and no charts", %{conn: conn, opts: opts} do
      item = seed_item(opts, kind: :pr, title: "a pull request", worker: "crew-a")
      append(item, %{type: :status, status: :merged}, opts)

      append(
        item,
        %{type: :contribution, worker: "crew-a", role: :implement, duration_ms: 900_000},
        opts
      )

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "merged"
      assert html =~ "a pull request"
      assert html =~ "crew-a"
      assert html =~ "15m"
      assert html =~ item.url
      # Charts live on /progress only; the home preview stays small.
      refute html =~ "Fleet telemetry"
    end
  end

  describe "/progress pagination" do
    test "page 1 shows the newest 20 and offers page 2", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/progress")

      assert html =~ title(25)
      assert html =~ title(6)
      refute html =~ title(5)
      assert html =~ "Showing 1–20 of 25"
      assert html =~ "page=2"
      assert html =~ "next"
    end

    test "page 2 shows the remainder with a prev link", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/progress?page=2")

      assert html =~ title(5)
      assert html =~ title(1)
      refute html =~ title(6)
      assert html =~ "Showing 21–25 of 25"
      assert html =~ "prev"
      assert html =~ "page=1"
    end

    test "patching to page 2 keeps the same LiveView", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, view, _html} = live(conn, ~p"/progress")
      html = view |> element("a", "next") |> render_click()

      assert html =~ title(1)
      assert html =~ "Showing 21–25 of 25"
    end

    test "keeps its empty state and hides the pager", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/progress")

      assert html =~ "No PRs, issues, or achievements recorded."
      refute html =~ "Showing"
    end

    test "hides the pager when everything fits on one page", %{conn: conn, opts: opts} do
      seed_items(opts, 20)

      {:ok, _view, html} = live(conn, ~p"/progress")

      assert html =~ "Showing 1–20 of 20"
      refute html =~ "page=2"
    end

    test "clamps a bad page param to page 1", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/progress?page=nope")

      assert html =~ title(25)
      assert html =~ "Showing 1–20 of 25"
    end

    test "clamps a page past the end to the last page", %{conn: conn, opts: opts} do
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/progress?page=99")

      assert html =~ "Showing 21–25 of 25"
      assert html =~ title(1)
    end
  end

  describe "details view" do
    setup %{opts: opts} do
      item =
        seed_item(opts,
          kind: :pr,
          title: "the detailed pull request",
          url: "https://github.com/carverauto/firstmate-port/pull/42"
        )

      append(item, %{type: :status, status: :merged, detail: "github poll"}, opts)
      append(item, %{type: :assignment, worker: "crew-first"}, opts)
      append(item, %{type: :assignment, worker: "crew-second"}, opts)

      append(
        item,
        %{
          type: :contribution,
          worker: "crew-second",
          role: :implement,
          runtime: "claude-code",
          model: "claude-opus-5",
          effort: "xhigh",
          duration_ms: 5_400_000,
          tokens: 128_000,
          interrupted: false
        },
        opts
      )

      append(
        item,
        %{
          type: :contribution,
          worker: "crew-reviewer",
          role: :review,
          runtime: "claude-code",
          model: "claude-sonnet-5",
          effort: "high",
          tokens: 12_000
        },
        opts
      )

      {:ok, item: item}
    end

    test "opens from the home dashboard and carries every field", %{
      conn: conn,
      item: item
    } do
      {:ok, _view, html} = live(conn, ~p"/?tab=progress&item=#{item.id}")

      assert html =~ "the detailed pull request"
      assert html =~ "merged"
      assert html =~ item.url
      # assignee history, newest first
      assert html =~ "crew-first"
      assert html =~ "crew-second"
      # each contributing worker with runtime, model and effort
      assert html =~ "claude-code"
      assert html =~ "claude-opus-5"
      assert html =~ "xhigh"
      # the review worker is called out as review
      assert html =~ "crew-reviewer"
      assert html =~ "role-review"
      # duration, tokens, interrupted
      assert html =~ "1h 30m"
      assert html =~ "140.0k"
      assert html =~ "Interrupted"
      # timestamps
      assert html =~ "UTC"
    end

    test "opens from /progress with the same component", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")

      assert html =~ "progress-details"
      assert html =~ "the detailed pull request"
      assert html =~ "claude-opus-5"
      assert html =~ "role-review"
    end

    test "the row's details control opens it in place", %{conn: conn, item: item} do
      {:ok, view, html} = live(conn, ~p"/progress")
      refute html =~ "aria-modal"

      opened = view |> element(~s{a[aria-label="Details for #{item.title}"]}) |> render_click()

      assert opened =~ "aria-modal"
      assert opened =~ "claude-opus-5"
      assert_patched(view, "/progress?page=1&item=#{item.id}")
    end

    test "closes back to the page it came from", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/progress?item=#{item.id}")

      closed = view |> element(~s{a[aria-label="Close details"]}) |> render_click()

      refute closed =~ "aria-modal"
      assert closed =~ "the detailed pull request"
    end

    test "Esc and the overlay both patch back to the same close path", %{
      conn: conn,
      item: item
    } do
      {:ok, _view, html} = live(conn, ~p"/progress?page=1&item=#{item.id}")

      assert html =~ ~s(phx-key="Escape")
      # Esc on the modal root and a click on the overlay both patch to /progress?page=1
      assert html =~ ~s(&quot;/progress?page=1&quot;)
      assert html =~ "modal-overlay"
    end

    test "a deep link to a row on a later page still opens", %{conn: conn, opts: opts} do
      older = seed_item(opts, title: "buried row")
      seed_items(opts, 25)

      {:ok, _view, html} = live(conn, ~p"/progress?item=#{older.id}")

      # It is not in page 1's table, but the details view still resolves it.
      assert html =~ "buried row"
      assert html =~ "aria-modal"
      # 25 seeded here, plus the buried row and the describe block's own item.
      assert html =~ "Showing 1–20 of 27"
    end

    test "an unknown item id leaves the page without a modal", %{conn: conn, opts: opts} do
      seed_items(opts, 3)

      {:ok, _view, html} = live(conn, ~p"/progress?item=no-such-row")

      refute html =~ "aria-modal"
      assert html =~ title(3)
    end

    test "an assignment without telemetry gets neutral observations", %{conn: conn, opts: opts} do
      bare = seed_item(opts, title: "nothing appended")

      {:ok, _view, html} = live(conn, ~p"/progress?item=#{bare.id}")

      assert html =~ "No additional observations."
      refute html =~ "Nothing appended yet"
      assert html =~ "No contributions reported on this page"
      assert html =~ "no telemetry yet"
      assert html =~ "derived from kind"
    end
  end

  describe "row click and modal visualizations" do
    setup %{opts: opts} do
      item =
        seed_item(opts,
          kind: :pr,
          title: "the visualized pull request",
          url: "https://github.com/carverauto/firstmate-port/pull/77",
          worker: "crew-opener"
        )

      append(item, %{type: :status, status: :draft, occurred_at: at(0)}, opts)
      append(item, %{type: :status, status: :in_progress, occurred_at: at(60)}, opts)
      append(item, %{type: :status, status: :ready_for_review, occurred_at: at(180)}, opts)
      append(item, %{type: :status, status: :merged, occurred_at: at(240)}, opts)

      append(
        item,
        %{
          type: :contribution,
          worker: "crew-opener",
          role: :implement,
          tokens: 300_000,
          duration_ms: 5_400_000,
          occurred_at: at(120)
        },
        opts
      )

      append(
        item,
        %{
          type: :contribution,
          worker: "crew-reviewer",
          role: :review,
          tokens: 40_000,
          occurred_at: at(200)
        },
        opts
      )

      {:ok, item: item}
    end

    test "clicking the row opens the details view", %{conn: conn, item: item} do
      {:ok, view, html} = live(conn, ~p"/progress")
      refute html =~ "aria-modal"

      opened = view |> element("tr#row-#{item.id}") |> render_click()

      assert opened =~ "aria-modal"
      assert opened =~ "the visualized pull request"
      assert_patched(view, "/progress?page=1&item=#{item.id}")
    end

    test "the GitHub link carries its own binding so it does not also open the modal", %{
      conn: conn,
      item: item
    } do
      {:ok, view, _html} = live(conn, ~p"/progress")

      # LiveView dispatches a click to the *closest* phx-click, so the title
      # link having one of its own is what stops the row handler from firing.
      assert has_element?(view, ~s{tr#row-#{item.id}[phx-click]})
      assert has_element?(view, ~s{tr#row-#{item.id} a[href="#{item.url}"][phx-click]})
    end

    test "the details view draws the status timeline", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")

      assert html =~ "Time in each status"
      assert html =~ "timeline-seg"
      # One key entry per status the row spent time in. The final merged status
      # has no width - it is where the work ended - so it is not a segment.
      for label <- ["draft", "in progress", "ready for review"] do
        assert html =~ label
      end

      # draft ran an hour, in progress two, ready for review one.
      assert html =~ "1h"
      assert html =~ "2h"
      assert html =~ ~s(aria-label="Time in each status. draft: 1h, in progress: 2h,)
    end

    test "the details view breaks tokens down by contributor", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")

      assert html =~ "Who spent what"
      assert html =~ "crew-reviewer (review)"
      # Formatted, not raw: a token count in a bar label reads as 300.0k.
      assert html =~ "300.0k"
      assert html =~ "40.0k"
    end

    test "the details view states start, completion and elapsed time", %{
      conn: conn,
      item: item
    } do
      {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")

      assert html =~ "Started"
      assert html =~ "Completed"
      assert html =~ "Elapsed"
      refute html =~ "still open"
    end

    test "an open row says so instead of inventing a completion", %{conn: conn, opts: opts} do
      open = seed_item(opts, kind: :pr, title: "still going", worker: "crew-a")
      append(open, %{type: :status, status: :in_progress}, opts)

      {:ok, _view, html} = live(conn, ~p"/progress?item=#{open.id}")

      assert html =~ "still open"
    end

    test "heuristics are derived and labelled as such", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/progress?item=#{item.id}")

      assert html =~ "Heuristics"
      assert html =~ "Derived from the log, not reported."
      assert html =~ "Reviewed by crew-reviewer."
      assert html =~ "2 crew members touched this"
      assert html =~ "start to finish"
    end
  end

  describe "charts" do
    test "render the status mix, durations and interruptions from the log", %{
      conn: conn,
      opts: opts
    } do
      merged = seed_item(opts, kind: :pr, title: "merged pr")
      append(merged, %{type: :status, status: :merged}, opts)

      append(
        merged,
        %{
          type: :contribution,
          worker: "crew-a",
          duration_ms: 5_400_000,
          tokens: 128_000,
          interrupted: true
        },
        opts
      )

      open = seed_item(opts, kind: :pr, title: "open pr")
      append(open, %{type: :status, status: :in_progress}, opts)
      seed_item(opts, kind: :achievement, title: "an achievement")

      {:ok, _view, html} = live(conn, ~p"/progress")

      assert html =~ "Fleet telemetry"
      assert html =~ "Status mix"
      assert html =~ "Duration distribution"
      assert html =~ "Interrupted"
      assert html =~ "Tokens spent"
      assert html =~ "128.0k"
      assert html =~ "1h 30m"
      # 1 of 3 items reported each metric
      assert html =~ "1 of 3 reported"
      assert html =~ "1–4h"
    end

    test "say so honestly when no telemetry has been reported", %{conn: conn, opts: opts} do
      seed_items(opts, 3)

      {:ok, _view, html} = live(conn, ~p"/progress")

      assert html =~ "Fleet telemetry"
      assert html =~ "no telemetry yet"
      assert html =~ "Nothing has reported how long a task took."
      # The status mix still draws: those three rows do have a status.
      assert html =~ "Status mix"
    end

    test "an empty tenant draws nothing rather than a zero", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/progress")

      assert html =~ "No progress rows yet."
      assert html =~ "no telemetry yet"

      # "0 interrupted" would read as "none were"; an empty log says nothing.
      tiles = view |> element(".kpis") |> render()
      assert tiles =~ "Interrupted"
      refute tiles =~ ~r/Interrupted<\/span><span class="kpi-value">0/
    end
  end

  describe "authorization" do
    test "/progress requires a signed-in user" do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/progress")
    end
  end

  describe "list API" do
    test "is bounded, reports its window, and carries the projection", %{
      opts: opts,
      api_key: api_key
    } do
      seed_items(opts, 60)
      merged = seed_item(opts, kind: :pr, title: "merged pr", worker: "crew-a")
      append(merged, %{type: :status, status: :merged}, opts)

      append(
        merged,
        %{
          type: :contribution,
          worker: "crew-a",
          role: :implement,
          tokens: 100,
          duration_ms: 60_000
        },
        opts
      )

      assert %{"data" => rows, "meta" => meta} = api_get(api_key, ~p"/api/progress")
      assert length(rows) == 50
      assert meta == %{"total" => 61, "limit" => 50, "offset" => 0}

      row = Enum.find(rows, &(&1["id"] == merged.id))
      assert row["status"] == "merged"
      assert row["status_source"] == "log"
      assert row["assignee"] == "crew-a"
      assert row["tokens"] == 100
      assert row["duration_ms"] == 60_000
      assert row["interrupted"] == "unknown"

      assert %{"data" => rows2, "meta" => meta2} =
               api_get(api_key, ~p"/api/progress?limit=20&offset=20")

      assert length(rows2) == 20
      assert meta2 == %{"total" => 61, "limit" => 20, "offset" => 20}

      assert %{"data" => rows3, "meta" => meta3} = api_get(api_key, ~p"/api/progress?limit=500")
      assert length(rows3) == 61
      assert meta3["limit"] == ProgressItem.max_page_size()
    end

    test "a single item comes back with its whole log", %{opts: opts, api_key: api_key} do
      item = seed_item(opts, kind: :pr, title: "one pr", worker: "crew-opener")
      append(item, %{type: :status, status: :merged}, opts)
      append(item, %{type: :contribution, worker: "crew-a", role: :review}, opts)

      body = api_get(api_key, ~p"/api/progress/#{item.id}")

      assert body["status"] == "merged"
      # The opening :assignment plus the two appended above.
      assert body["event_count"] == 3

      assert [
               %{"type" => "assignment", "worker" => "crew-opener"},
               %{"type" => "status"},
               %{"type" => "contribution", "role" => "review"}
             ] = body["events"]
    end

    test "an unknown id is a 404", %{api_key: api_key} do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> get(~p"/api/progress/nope")

      assert json_response(conn, 404)
    end
  end

  defp at(minutes), do: DateTime.add(~U[2026-01-01 00:00:00.000000Z], minutes, :minute)

  defp api_get(api_key, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> get(path)
    |> json_response(200)
  end
end
