defmodule FirstmatePort.Portal.ProgressLogTest do
  @moduledoc """
  The write side. A poll that keeps seeing the same status must not keep
  appending it, and naming an item that does not exist must not create one.
  """

  use FirstmatePort.DataCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem, ProgressLog}

  setup do
    ctx = agent_context("progress-log")

    item =
      seed_item(ctx.opts,
        kind: :pr,
        title: "a pull request",
        url: "https://github.com/carverauto/firstmate-port/pull/1"
      )

    {:ok, Map.put(ctx, :item, item)}
  end

  test "repeated historical observations append the transition only once", ctx do
    at = ~U[2026-09-01 12:00:00.000000Z]

    append(
      ctx.item,
      %{type: :status, status: :in_progress, occurred_at: DateTime.add(at, 60)},
      ctx.opts
    )

    assert {:ok, :appended, event} =
             ProgressLog.record_observed_status(ctx.item, :merged, %{occurred_at: at}, ctx.opts)

    assert {:ok, :unchanged, :merged} =
             ProgressLog.record_observed_status(ctx.item, :merged, %{occurred_at: at}, ctx.opts)

    assert {:ok, :unchanged, :merged} =
             ProgressLog.record_observed_status(ctx.item, :merged, %{occurred_at: at}, ctx.opts)

    assert {:ok, events} = ProgressEvent.list_for_item(ctx.item.id, ctx.opts)
    assert [%{id: id, occurred_at: ^at}] = Enum.filter(events, &(&1.status == :merged))
    assert id == event.id

    assert {:ok, [%{status: :in_progress}]} =
             FirstmatePort.Portal.ProgressProjection.load([ctx.item], ctx.opts)
  end

  test "observations preserve crew judgements and deduplicate terminal states", ctx do
    append(ctx.item, %{type: :status, status: :ready_for_review}, ctx.opts)

    assert {:ok, :ignored, :in_progress} =
             ProgressLog.record_observed_status(ctx.item, :in_progress, %{}, ctx.opts)

    assert {:ok, :appended, event} =
             ProgressLog.record_observed_status(
               ctx.item,
               :merged,
               %{detail: "github poll"},
               ctx.opts
             )

    assert event.detail == "github poll"

    assert {:ok, :unchanged, :merged} =
             ProgressLog.record_observed_status(ctx.item, :merged, %{}, ctx.opts)

    assert {:ok, 3} = Ash.count(ProgressEvent, ctx.opts)
  end

  describe "find_item/2" do
    test "finds by portal id", ctx do
      assert {:ok, found} = ProgressLog.find_item(%{"item_id" => ctx.item.id}, ctx.opts)
      assert found.id == ctx.item.id
    end

    test "finds by the GitHub URL the producer already holds", ctx do
      assert {:ok, found} = ProgressLog.find_item(%{"url" => ctx.item.url}, ctx.opts)
      assert found.id == ctx.item.id
    end

    test "a URL nobody recorded is not found, and nothing is created", ctx do
      before = Ash.count!(ProgressItem, ctx.opts)

      assert {:error, :not_found} =
               ProgressLog.find_item(
                 %{"url" => "https://github.com/carverauto/firstmate-port/pull/999"},
                 ctx.opts
               )

      assert {:error, :not_found} = ProgressLog.find_item(%{"item_id" => "nope"}, ctx.opts)
      assert {:error, :not_found} = ProgressLog.find_item(%{}, ctx.opts)
      assert Ash.count!(ProgressItem, ctx.opts) == before
    end
  end
end

