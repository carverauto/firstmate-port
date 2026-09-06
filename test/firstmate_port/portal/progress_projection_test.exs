defmodule FirstmatePort.Portal.ProgressProjectionTest do
  @moduledoc """
  The projection is the only thing the UI reads, so these tests pin the two
  properties the captain asked for: newest event wins for the single-value
  fields, and every contribution survives for the details view.
  """

  use FirstmatePort.DataCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Portal.{ProgressProjection, ProgressStatus}

  setup do
    ctx = agent_context("progress-projection")

    {:ok,
     Map.put(
       ctx,
       :item,
       seed_item(ctx.opts, kind: :pr, title: "a pull request", worker: "crew-a")
     )}
  end

  test "an unfinished status has no measured endpoint or duration", ctx do
    started = DateTime.utc_now()
    append(ctx.item, %{type: :status, status: :in_progress, occurred_at: started}, ctx.opts)

    assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)

    assert [%{status: :in_progress, to: nil, duration_ms: nil, open?: true}] =
             projection.status_spans

    append(
      ctx.item,
      %{type: :note, detail: "still working", occurred_at: DateTime.add(started, 3600)},
      ctx.opts
    )

    assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
    assert [%{to: nil, duration_ms: nil, open?: true}] = projection.status_spans

    finished = DateTime.add(started, 7200)
    append(ctx.item, %{type: :status, status: :merged, occurred_at: finished}, ctx.opts)
    assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
    assert [%{to: ^finished, duration_ms: 7_200_000, open?: false}] = projection.status_spans
  end

  describe "status" do
    test "an empty log falls back to the kind, and says so", ctx do
      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.status == :in_progress
      assert projection.status_source == :kind
      assert projection.status_at == nil
    end

    test "an achievement with an empty log reads as complete", ctx do
      item = seed_item(ctx.opts, kind: :achievement, title: "shipped it")
      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :complete
      assert projection.status_source == :kind
    end

    test "the newest status event wins", ctx do
      append(ctx.item, %{type: :status, status: :in_progress, occurred_at: at(1)}, ctx.opts)
      append(ctx.item, %{type: :status, status: :merged, occurred_at: at(2)}, ctx.opts)

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.status == :merged
      assert projection.status_source == :log
      assert projection.status_at == at(2)
    end

    test "newest means newest by occurred_at, not by insertion order", ctx do
      append(ctx.item, %{type: :status, status: :merged, occurred_at: at(9)}, ctx.opts)
      append(ctx.item, %{type: :status, status: :in_progress, occurred_at: at(1)}, ctx.opts)

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.status == :merged
    end

    test "going back to in progress is just another append", ctx do
      append(ctx.item, %{type: :status, status: :merged, occurred_at: at(1)}, ctx.opts)
      append(ctx.item, %{type: :status, status: :in_progress, occurred_at: at(2)}, ctx.opts)

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.status == :in_progress
      # The opening :assignment plus the two statuses.
      assert length(projection.events) == 3
    end
  end

  describe "assignment and contributions" do
    test "the opening :assignment event names the crew member", ctx do
      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.assignee == "crew-a"
      assert projection.assignee_source == :assignment
      assert projection.workers == ["crew-a"]
      assert [%{type: :assignment, worker: "crew-a"}] = projection.events
    end

    test "a row from before crew attribution reads as unassigned", ctx do
      legacy = seed_legacy_item(ctx.opts, kind: :pr, title: "polled long ago")

      assert {:ok, projection} = ProgressProjection.load_one(legacy, ctx.opts)
      assert projection.assignee == nil
      assert projection.workers == []
      assert projection.events == []
    end

    test "the newest assignment wins and the history is kept newest first", ctx do
      # No explicit timestamp: this lands after the row's own opening event.
      append(ctx.item, %{type: :assignment, worker: "crew-b"}, ctx.opts)

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.assignee == "crew-b"
      assert projection.assignee_source == :assignment
      assert Enum.map(projection.assignments, & &1.worker) == ["crew-b", "crew-a"]
    end

    test "every contributor survives, with runtime, model, effort and role", ctx do
      append(
        ctx.item,
        %{
          type: :contribution,
          worker: "crew-a",
          role: :implement,
          runtime: "claude-code",
          model: "claude-opus-5",
          effort: "xhigh",
          occurred_at: at(1)
        },
        ctx.opts
      )

      append(
        ctx.item,
        %{
          type: :contribution,
          worker: "crew-reviewer",
          role: :review,
          runtime: "claude-code",
          model: "claude-sonnet-5",
          effort: "high",
          occurred_at: at(2)
        },
        ctx.opts
      )

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert Enum.map(projection.contributions, & &1.worker) == ["crew-a", "crew-reviewer"]
      assert Enum.map(projection.reviewers, & &1.worker) == ["crew-reviewer"]
      assert projection.workers == ["crew-a", "crew-reviewer"]

      [implement, review] = projection.contributions
      assert implement.model == "claude-opus-5"
      assert implement.effort == "xhigh"
      assert review.runtime == "claude-code"
      assert review.role == :review
    end

    test "a worker who appears twice is counted once", ctx do
      append(
        ctx.item,
        %{type: :contribution, worker: "crew-a", role: :implement, occurred_at: at(2)},
        ctx.opts
      )

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.workers == ["crew-a"]
    end
  end

  describe "telemetry" do
    test "nothing reported stays nil and unknown, never zero", ctx do
      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.duration_ms == nil
      assert projection.tokens == nil
      assert projection.interrupted == :unknown
    end

    test "duration and tokens sum across contributions", ctx do
      append(
        ctx.item,
        %{
          type: :contribution,
          worker: "crew-a",
          duration_ms: 60_000,
          tokens: 1_000,
          occurred_at: at(1)
        },
        ctx.opts
      )

      append(
        ctx.item,
        %{
          type: :contribution,
          worker: "crew-b",
          duration_ms: 30_000,
          tokens: 500,
          occurred_at: at(2)
        },
        ctx.opts
      )

      assert {:ok, projection} = ProgressProjection.load_one(ctx.item, ctx.opts)
      assert projection.duration_ms == 90_000
      assert projection.tokens == 1_500
    end

    test "interrupted is yes / no / unknown, and any yes wins", ctx do
      append(
        ctx.item,
        %{type: :contribution, worker: "crew-a", interrupted: false, occurred_at: at(1)},
        ctx.opts
      )

      assert {:ok, %{interrupted: :no}} = ProgressProjection.load_one(ctx.item, ctx.opts)

      append(ctx.item, %{type: :interruption, interrupted: true, occurred_at: at(2)}, ctx.opts)
      assert {:ok, %{interrupted: :yes}} = ProgressProjection.load_one(ctx.item, ctx.opts)
    end
  end

  test "summaries include events beyond a bounded history page", ctx do
    for _ <- 1..120 do
      append(
        ctx.item,
        %{type: :contribution, role: :review, worker: "reviewer", tokens: 1, duration_ms: 10},
        ctx.opts
      )
    end

    append(ctx.item, %{type: :status, status: :merged}, ctx.opts)

    assert {:ok, [summary]} = ProgressProjection.load([ctx.item], ctx.opts)
    assert summary.events == []
    assert summary.status == :merged
    assert summary.tokens == 120
    assert summary.duration_ms == 1200
    assert summary.review_count == 120
    assert summary.event_count == 122

    assert {:ok, first} = ProgressProjection.load_one(ctx.item, ctx.opts)
    assert length(first.events) == 100
    assert first.tokens == 120
    assert first.status == :merged
    assert {:ok, last} = ProgressProjection.load_one(ctx.item, ctx.opts, 100, 100)
    assert length(last.events) == 22
    assert List.last(last.events).status == :merged
    assert last.event_count == 122
    assert {:ok, stats, false} = ProgressProjection.tenant_stats(ctx.opts)
    assert stats.tokens_total == 120
    assert stats.review_total == 1
  end

  describe "load/2" do
    test "projects a page of items in one query, preserving order", ctx do
      [a, b, c] = seed_items(ctx.opts, 3)
      append(b, %{type: :status, status: :merged}, ctx.opts)

      assert {:ok, projections} = ProgressProjection.load([c, b, a], ctx.opts)
      assert Enum.map(projections, & &1.item.id) == [c.id, b.id, a.id]
      assert Enum.map(projections, & &1.status) == [:complete, :merged, :complete]
    end

    test "an empty page needs no query at all", ctx do
      assert {:ok, []} = ProgressProjection.load([], ctx.opts)
    end
  end

  describe "stats/1" do
    test "an empty tenant reports zeros and no telemetry", ctx do
      assert {:ok, stats, capped} = ProgressProjection.tenant_stats(ctx.opts)
      refute capped
      assert stats.total == 1
      assert stats.duration_tracked == 0
      assert stats.tokens_tracked == 0
      assert stats.tokens_total == nil
      assert stats.duration_total_ms == nil
      assert stats.interrupted_counts == %{yes: 0, no: 0, unknown: 1}
    end

    test "counts the status mix over every public status", ctx do
      merged = seed_item(ctx.opts, kind: :pr, title: "merged one")
      append(merged, %{type: :status, status: :merged}, ctx.opts)
      seed_item(ctx.opts, kind: :achievement, title: "done")

      assert {:ok, stats, _} = ProgressProjection.tenant_stats(ctx.opts)
      assert Map.keys(stats.status_counts) |> Enum.sort() == Enum.sort(ProgressStatus.all())
      assert stats.status_counts.merged == 1
      assert stats.status_counts.complete == 1
      assert stats.status_counts.in_progress == 1
      assert stats.total == 3
    end

    test "buckets durations and totals tokens only from what was reported", ctx do
      quick = seed_item(ctx.opts, title: "quick")
      long = seed_item(ctx.opts, title: "long")

      append(
        quick,
        %{type: :contribution, worker: "a", duration_ms: 60_000, tokens: 100},
        ctx.opts
      )

      append(
        long,
        %{type: :contribution, worker: "b", duration_ms: 7_200_000, tokens: 900},
        ctx.opts
      )

      assert {:ok, stats, _} = ProgressProjection.tenant_stats(ctx.opts)
      assert stats.duration_tracked == 2
      assert stats.tokens_total == 1_000
      assert stats.duration_total_ms == 7_260_000

      buckets = Map.new(stats.duration_buckets, &{&1.label, &1.count})
      assert buckets["<5m"] == 1
      assert buckets["1–4h"] == 1
      assert buckets["4h+"] == 0

      assert Enum.map(stats.duration_buckets, & &1.label) ==
               ProgressProjection.duration_bucket_labels()
    end
  end

  defp at(n), do: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n, :minute)
end
