defmodule FirstmatePortWeb.ProgressEvidenceTest do
  @moduledoc """
  Exercises ingestion through the signed-in progress surfaces. Set
  FIRSTMATE_PROGRESS_EVIDENCE_DIR to export API output and rendered pages;
  build the CSS assets first when requesting visual evidence.
  """
  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FirstmatePort.ProgressFixtures

  test "ingested crew history appears in dashboard and archive details", %{conn: conn} do
    ctx = agent_context("visual-progress")
    seed_items(ctx.opts, 24)
    seed_legacy_item(ctx.opts, kind: :pr, title: "Unworked org import")

    item =
      post_json(ctx, "/api/progress", %{
        kind: "pr",
        title: "Ship crew progress tracking",
        url: "https://github.com/example/fleet/pull/42",
        worker: "crew-builder",
        assigned_at: "2026-09-05T10:00:00Z"
      })

    for event <- history() do
      post_json(ctx, "/api/progress/events", Map.put(event, :item_id, item["id"]))
    end

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{ctx.api_key}")
      |> get("/api/progress/#{item["id"]}")
      |> json_response(200)

    assert %{
             "assignee" => "crew-finisher",
             "status" => "merged",
             "duration_ms" => 3_000_000,
             "tokens" => 37_000,
             "interrupted" => "yes",
             "review_count" => 1,
             "worker_count" => 3,
             "meta" => %{"total" => 8}
           } = response

    if evidence = System.get_env("FIRSTMATE_PROGRESS_EVIDENCE_DIR") do
      File.mkdir_p!(evidence)
      File.write!(Path.join(evidence, "progress-api.json"), Jason.encode!(response, pretty: true))
    end

    {:ok, token, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human("visual"), %{})
    conn = conn |> init_test_session(%{}) |> put_session(:guardian_token, token)
    {:ok, home, html} = live(conn, "/?tab=progress")
    assert html =~ "See all 25"
    refute html =~ "Unworked org import"

    rows =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#progress-preview tbody tr")
      |> Enum.to_list()

    assert length(rows) == 10
    save("dashboard", html)

    detail =
      home
      |> element("a[aria-label='Details for Ship crew progress tracking']")
      |> render_click()

    assert detail =~ "crew-reviewer"
    assert detail =~ "gpt-6"
    save("dashboard-details", detail)

    {:ok, archive, html} = live(conn, "/progress")
    assert html =~ "of 25"
    save("progress", html)

    next = archive |> element("a[rel=next]") |> render_click()
    assert next =~ "21–25 of 25"
    save("progress-page-2", next)

    {:ok, _, detail} = live(conn, "/progress?item=#{item["id"]}")
    assert detail =~ "crew-finisher"
    save("progress-details", detail)
  end

  defp post_json(ctx, path, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{ctx.api_key}")
    |> post(path, params)
    |> json_response(200)
  end

  defp history do
    [
      %{
        type: "assignment",
        worker: "crew-builder",
        runtime: "codex",
        model: "gpt-6",
        effort: "high",
        occurred_at: "2026-09-05T10:00:01Z"
      },
      %{type: "status", status: "in_progress", occurred_at: "2026-09-05T10:01:00Z"},
      %{
        type: "contribution",
        worker: "crew-builder",
        role: "implement",
        runtime: "codex",
        model: "gpt-6",
        effort: "high",
        tokens: 28000,
        duration_ms: 2_400_000,
        interrupted: true,
        occurred_at: "2026-09-05T10:40:00Z"
      },
      %{
        type: "assignment",
        worker: "crew-finisher",
        runtime: "codex",
        model: "gpt-6",
        effort: "high",
        occurred_at: "2026-09-05T10:41:00Z"
      },
      %{
        type: "contribution",
        worker: "crew-reviewer",
        role: "review",
        runtime: "codex",
        model: "gpt-6",
        effort: "high",
        tokens: 9000,
        duration_ms: 600_000,
        occurred_at: "2026-09-05T10:50:00Z"
      },
      %{type: "status", status: "complete", occurred_at: "2026-09-05T10:55:00Z"},
      %{type: "status", status: "merged", occurred_at: "2026-09-05T11:00:00Z"}
    ]
  end

  defp save(name, html) do
    if evidence = System.get_env("FIRSTMATE_PROGRESS_EVIDENCE_DIR") do
      css = File.read!("priv/static/assets/css/app.css")

      css =
        Enum.reduce(["geist-sans", "geist-mono"], css, fn font, css ->
          data = Base.encode64(File.read!("priv/static/fonts/#{font}.woff2"))
          String.replace(css, "/fonts/#{font}.woff2", "data:font/woff2;base64," <> data)
        end)

      html =
        Enum.reduce(["steering-wheel-black", "steering-wheel-white"], html, fn name, html ->
          data = Base.encode64(File.read!("priv/static/images/#{name}.svg"))
          String.replace(html, "/images/#{name}.svg", "data:image/svg+xml;base64," <> data)
        end)

      document = """
      <!doctype html>
      <html data-theme="light">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>#{css}</style>
      </head>
      <body>#{html}</body>
      </html>
      """

      File.write!(Path.join(evidence, name <> ".html"), document)
    end
  end
end
