defmodule FirstmatePort.Portal.ProgressEventTest do
  @moduledoc """
  The fleet log is append-only. These tests hold that line at the resource
  level: there is no action to update or destroy an event, and the payload each
  event type needs is required at append time.
  """

  use FirstmatePort.DataCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem}
  alias FirstmatePort.Tenancy

  setup do
    ctx = agent_context("progress-event")
    {:ok, Map.put(ctx, :item, seed_item(ctx.opts, title: "an item"))}
  end

  describe "append-only" do
    test "the resource exposes no update or destroy action" do
      types =
        ProgressEvent
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.type)
        |> Enum.uniq()
        |> Enum.sort()

      assert types == [:create, :read]

      refute :update in types,
             "an update action would let an agent rewrite fleet-log history"

      refute :destroy in types,
             "a destroy action would let an agent delete fleet-log history"
    end

    test "the only create action is :append" do
      creates =
        ProgressEvent
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&(&1.type == :create))
        |> Enum.map(& &1.name)

      assert creates == [:append]
    end

    test "a status change appends a second row rather than editing the first", ctx do
      first = append(ctx.item, %{type: :status, status: :in_progress}, ctx.opts)
      second = append(ctx.item, %{type: :status, status: :merged}, ctx.opts)

      assert {:ok, events} = ProgressEvent.list_for_item(ctx.item.id, ctx.opts)

      # The row opened with its :assignment event; the two statuses follow it.
      assert [%{type: :assignment} = seed, one, two] = events
      assert [one.id, two.id] == [first.id, second.id]
      assert seed.worker == default_worker()
      assert Enum.map(events, & &1.status) == [nil, :in_progress, :merged]
    end
  end

  test "subject changes project title and kind without rewriting identity", ctx do
    assert {:ok, event} =
             ProgressEvent.append(
               %{item_id: ctx.item.id, type: :subject, title: "Renamed", kind: :achievement},
               ctx.opts
             )

    assert {:ok, item} = ProgressItem.get_by_id(ctx.item.id, ctx.opts)
    assert {item.title, item.kind} == {"Renamed", :achievement}

    assert %{rows: [[title, kind]]} =
             FirstmatePort.Repo.query!(
               "SELECT title, kind FROM progress_items WHERE id = $1",
               [item.id]
             )

    assert {title, kind} == {ctx.item.title, Atom.to_string(ctx.item.kind)}
    projection = FirstmatePort.Portal.ProgressProjection.project(ctx.item, [event])
    assert {projection.item.title, projection.item.kind} == {"Renamed", :achievement}
    assert {:ok, loaded} = FirstmatePort.Portal.ProgressProjection.load_one(ctx.item, ctx.opts)
    assert loaded.item.title == "Renamed"
  end

  describe "payload validation" do
    test "a :status event needs a status", ctx do
      assert {:error, error} =
               ProgressEvent.append(%{item_id: ctx.item.id, type: :status}, ctx.opts)

      assert Exception.message(error) =~ "status"
    end

    test "a :contribution event needs a worker", ctx do
      assert {:error, error} =
               ProgressEvent.append(
                 %{item_id: ctx.item.id, type: :contribution, model: "claude-opus-5"},
                 ctx.opts
               )

      assert Exception.message(error) =~ "worker"
    end

    test "an :interruption event needs the flag set", ctx do
      assert {:error, _} =
               ProgressEvent.append(%{item_id: ctx.item.id, type: :interruption}, ctx.opts)

      assert {:ok, event} =
               ProgressEvent.append(
                 %{item_id: ctx.item.id, type: :interruption, interrupted: true},
                 ctx.opts
               )

      assert event.interrupted
    end

    test "an unknown type is rejected", ctx do
      assert {:error, _} =
               ProgressEvent.append(%{item_id: ctx.item.id, type: :reassigned}, ctx.opts)
    end

    test "occurred_at defaults to now but an explicit value is kept", ctx do
      backdated = ~U[2026-01-02 03:04:05.000000Z]

      assert %{occurred_at: %DateTime{}} =
               append(ctx.item, %{type: :note, detail: "no timestamp given"}, ctx.opts)

      assert %{occurred_at: ^backdated} =
               append(
                 ctx.item,
                 %{type: :note, detail: "backdated", occurred_at: backdated},
                 ctx.opts
               )
    end
  end

  describe "authorization and tenancy" do
    test "a human actor may read but not append", ctx do
      append(ctx.item, %{type: :status, status: :merged}, ctx.opts)
      human_opts = Tenancy.opts(human("event-reader"))

      assert {:ok, [%{type: :assignment}, %{type: :status}]} =
               ProgressEvent.list_for_item(ctx.item.id, human_opts)

      assert {:error, _} =
               ProgressEvent.append(
                 %{item_id: ctx.item.id, type: :status, status: :complete},
                 human_opts
               )
    end

    test "events do not leak across tenants", ctx do
      append(ctx.item, %{type: :status, status: :merged}, ctx.opts)
      other = Tenancy.opts(%{ctx.agent | tenant_slug: "other"})

      assert {:ok, []} = ProgressEvent.list_for_item(ctx.item.id, other)
      assert {:ok, 0} = Ash.count(ProgressEvent, other)
      # The item's own :assignment event plus the status appended above.
      assert {:ok, 2} = Ash.count(ProgressEvent, ctx.opts)
    end
  end

  describe "crew attribution" do
    test "a row cannot be opened without naming the crew member doing the work", ctx do
      assert {:error, error} =
               ProgressItem.record(%{kind: :note, title: "orphan work"}, ctx.opts)

      assert Exception.message(error) =~ "worker"
      assert {:ok, 1} = Ash.count(ProgressItem, ctx.opts)
    end

    test "a blank worker is not a worker", ctx do
      assert {:error, _} =
               ProgressItem.record(%{kind: :note, title: "blank", worker: ""}, ctx.opts)

      assert {:error, _} =
               ProgressItem.record(%{kind: :note, title: "nil", worker: nil}, ctx.opts)
    end

    test "opening a row appends the :assignment event that explains it", ctx do
      item = seed_item(ctx.opts, title: "claimed work", worker: "crew-claimer")

      assert {:ok, [event]} = ProgressEvent.list_for_item(item.id, ctx.opts)
      assert event.type == :assignment
      assert event.worker == "crew-claimer"
      assert event.occurred_at == item.inserted_at
    end

    test "the worker is not stored on the row; only the log knows it", ctx do
      item = seed_item(ctx.opts, title: "claimed work", worker: "crew-claimer")

      refute Map.has_key?(item, :worker)
      refute :worker in Enum.map(Ash.Resource.Info.attributes(ProgressItem), & &1.name)
    end
  end

  test "an event cannot name an item that does not exist", ctx do
    assert {:error, _} =
             ProgressEvent.append(
               %{item_id: "no-such-item", type: :status, status: :merged},
               ctx.opts
             )

    assert {:ok, 0} = Ash.count(ProgressItem, Tenancy.opts(%{ctx.agent | tenant_slug: "other"}))
  end
end
