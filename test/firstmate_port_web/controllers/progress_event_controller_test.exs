defmodule FirstmatePortWeb.Api.ProgressEventControllerTest do
  @moduledoc """
  The ingest contract producers code against: `POST /api/progress/events`.
  Documented in `docs/progress.md`; these tests are what keeps that doc honest.
  """

  use FirstmatePortWeb.ConnCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem}

  setup do
    ctx = agent_context("progress-ingest")

    item =
      seed_item(ctx.opts,
        kind: :pr,
        title: "an ingested pull request",
        url: "https://github.com/carverauto/firstmate-port/pull/7"
      )

    {:ok, Map.put(ctx, :item, item)}
  end

  defp post_event(api_key, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> post(~p"/api/progress/events", params)
  end

  test "accepts a rich contribution and echoes it back", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "contribution",
        "worker" => "fm-port-progress-page",
        "role" => "implement",
        "runtime" => "claude-code",
        "model" => "claude-opus-5",
        "effort" => "xhigh",
        "duration_ms" => 5_400_000,
        "tokens" => 128_000,
        "interrupted" => false,
        "detail" => "first pass",
        "occurred_at" => "2026-09-06T01:00:00Z"
      })

    assert body = json_response(conn, 200)
    assert body["item_id"] == ctx.item.id
    assert body["type"] == "contribution"
    assert body["role"] == "implement"
    assert body["model"] == "claude-opus-5"
    assert body["effort"] == "xhigh"
    assert body["duration_ms"] == 5_400_000
    assert body["tokens"] == 128_000
    assert body["interrupted"] == false
    assert body["occurred_at"] =~ "2026-09-06T01:00:00"
  end

  test "names the item by URL when the producer only has the GitHub link", ctx do
    conn =
      post_event(ctx.api_key, %{
        "url" => ctx.item.url,
        "type" => "status",
        "status" => "merged"
      })

    assert %{"item_id" => item_id, "status" => "merged"} = json_response(conn, 200)
    assert item_id == ctx.item.id
  end

  test "accepts the hyphenated status spelling", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "status",
        "status" => "in-progress"
      })

    assert %{"status" => "in_progress"} = json_response(conn, 200)
  end

  test "each post appends; nothing is ever replaced", ctx do
    post_event(ctx.api_key, %{
      "item_id" => ctx.item.id,
      "type" => "status",
      "status" => "in-progress"
    })

    post_event(ctx.api_key, %{"item_id" => ctx.item.id, "type" => "status", "status" => "merged"})

    assert {:ok, events} = ProgressEvent.list_for_item(ctx.item.id, ctx.opts)
    # The row's opening :assignment event, then the two statuses.
    assert Enum.map(events, & &1.type) == [:assignment, :status, :status]
    assert Enum.map(events, & &1.status) == [nil, :in_progress, :merged]
  end

  test "an unknown item is a 404 and creates nothing", ctx do
    before = Ash.count!(ProgressItem, ctx.opts)

    conn =
      post_event(ctx.api_key, %{
        "url" => "https://github.com/carverauto/firstmate-port/pull/9999",
        "type" => "status",
        "status" => "merged"
      })

    assert json_response(conn, 404)["error"] =~ "no progress item"
    assert Ash.count!(ProgressItem, ctx.opts) == before
    # Only the row's own opening event; nothing was appended.
    assert {:ok, 1} = Ash.count(ProgressEvent, ctx.opts)
  end

  test "rejects a type outside the vocabulary", ctx do
    conn = post_event(ctx.api_key, %{"item_id" => ctx.item.id, "type" => "reassigned"})

    assert json_response(conn, 400)["error"] =~ "type must be one of"
  end

  test "rejects a fourth status", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "status",
        "status" => "abandoned"
      })

    assert json_response(conn, 400)["error"] =~ "status must be one of"
  end

  test "rejects a role outside implement and review", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "contribution",
        "worker" => "crew-a",
        "role" => "supervise"
      })

    assert json_response(conn, 400)["error"] =~ "role must be one of"
  end

  test "rejects a malformed occurred_at", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "note",
        "detail" => "hello",
        "occurred_at" => "yesterday"
      })

    assert json_response(conn, 400)["error"] =~ "ISO 8601"
  end

  test "rejects a payload the event type cannot carry", ctx do
    conn =
      post_event(ctx.api_key, %{
        "item_id" => ctx.item.id,
        "type" => "contribution",
        "model" => "claude-opus-5"
      })

    assert json_response(conn, 422)["error"] =~ "worker"
  end

  test "a browser user cannot append to the log", ctx do
    {:ok, token, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human("ingest"), %{})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/progress/events", %{
        "item_id" => ctx.item.id,
        "type" => "status",
        "status" => "merged"
      })

    assert conn.status in [401, 403]
    assert {:ok, 1} = Ash.count(ProgressEvent, ctx.opts)
  end
end
