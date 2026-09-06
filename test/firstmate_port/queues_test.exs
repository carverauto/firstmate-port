defmodule FirstmatePort.QueuesTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Queues
  alias FirstmatePort.Queues.{Entry, Tracker}

  setup context do
    slug =
      "t-" <> (context.test |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase())

    %{name: start_tracker(:"tracker_#{slug}"), tenant: slug}
  end

  defp start_tracker(name, sweep_ms \\ nil) do
    start_supervised!(%{
      id: name,
      start: {Tracker, :start_link, [[name: name, sweep_ms: sweep_ms]]}
    })

    name
  end

  describe "subjects" do
    test "queue facts ride the tenant's existing steer stream" do
      assert Queues.subject("acme") == "acme.steer.queue"

      # Covered by the tenant's own `acme.steer.>` filter: no new stream, no catch-all.
      assert ["acme.steer.>"] = FirstmatePort.Tenancy.steer_subjects("acme")

      assert Queues.subject?("acme.steer.queue")
      refute Queues.subject?("acme.steer.inbox")
      refute Queues.subject?("acme.discord.inbound")
    end
  end

  describe "reports" do
    test "a first report seeds the defaults a worker did not send", ctx do
      {:ok, entry} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "fm-port-queue-track"})

      assert entry.task == "fm-port-queue-track"
      assert entry.tenant_slug == ctx.tenant
      assert entry.status == :queued
      assert entry.tokens_in == 0
      assert entry.tokens_out == 0
      assert entry.started_at
      refute entry.stopped_at
    end

    test "later reports fill in the fields the first one left out", ctx do
      {:ok, _} =
        Tracker.track(ctx.name, ctx.tenant, %{
          "task" => "t1",
          "worker" => "crew-3",
          "agent_id" => "agent-abc",
          "model" => "claude-opus-5",
          "effort" => "high"
        })

      {:ok, entry} =
        Tracker.track(ctx.name, ctx.tenant, %{
          "task" => "t1",
          "status" => "working",
          "tokens_in" => 1200,
          "tokens_out" => 340
        })

      assert entry.worker == "crew-3"
      assert entry.agent_id == "agent-abc"
      assert entry.model == "claude-opus-5"
      assert entry.effort == "high"
      assert entry.status == :working
      assert Entry.tokens_total(entry) == 1540
    end

    test "a report is rejected without a task id", ctx do
      assert {:error, :missing_task} =
               Tracker.track(ctx.name, ctx.tenant, %{"worker" => "crew-3"})
    end

    test "an unknown status is rejected rather than silently dropped", ctx do
      assert {:error, :invalid_status} =
               Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "vibing"})
    end

    test "hyphenated statuses match the firstmate status lines", ctx do
      {:ok, entry} =
        Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "needs-decision"})

      assert entry.status == :needs_decision
    end

    test "token counters only climb, so a duplicate delivery cannot regress them", ctx do
      {:ok, _} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "tokens_in" => 900})
      {:ok, entry} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "tokens_in" => 100})
      assert entry.tokens_in == 900
    end

    test "a terminal report stops the clock and resuming starts it again", ctx do
      {:ok, _} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "working"})
      {:ok, done} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "done"})

      assert Entry.terminal?(done)
      assert done.stopped_at
      assert Entry.duration_ms(done) == Entry.duration_ms(done, DateTime.utc_now())

      {:ok, resumed} =
        Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "working"})

      refute Entry.terminal?(resumed)
      refute resumed.stopped_at
    end
  end

  test "stale snapshots cannot replace newer state", ctx do
    {:ok, working} =
      Tracker.track(ctx.name, ctx.tenant, %{
        "task" => "t1",
        "status" => "working",
        "worker" => "old",
        "updated_at" => "2026-09-05T10:00:00Z"
      })

    {:ok, done} =
      Tracker.track(ctx.name, ctx.tenant, %{
        "task" => "t1",
        "status" => "done",
        "worker" => "new",
        "tokens_in" => 100,
        "updated_at" => "2026-09-05T10:01:00Z"
      })

    Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Tracker.topic(ctx.tenant))
    assert {:ok, ^done} = Tracker.track(ctx.name, ctx.tenant, Entry.to_map(working))
    assert [^done] = Tracker.list(ctx.name, ctx.tenant)
    refute_receive {:queue_entry, _}, 50
  end

  test "wrong field types return errors without losing tenant entries", ctx do
    {:ok, prior} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "saved"})
    other = ctx.tenant <> "-other"
    {:ok, theirs} = Tracker.track(ctx.name, other, %{"task" => "saved"})

    for field <-
          ~w(task worker agent_id model effort summary status tokens_in tokens_out started_at stopped_at updated_at),
        value <- [false, [], %{}, 1.5] do
      params = Map.put(%{"task" => "bad"}, field, value)
      assert {:error, _} = Entry.new(ctx.tenant, params)
      assert {:error, _} = Tracker.track(ctx.name, ctx.tenant, params)
    end

    assert {:error, :invalid_status} =
             Tracker.track(ctx.name, ctx.tenant, %{"task" => "bad", "status" => 1})

    assert [^prior] = Tracker.list(ctx.name, ctx.tenant)
    assert [^theirs] = Tracker.list(ctx.name, other)
  end

  test "only canonical field names populate entries", ctx do
    for alias <- ~w(task_id id) do
      assert {:error, :missing_task} = Entry.new(ctx.tenant, %{alias => "t1"})
    end

    assert {:ok, entry} =
             Entry.new(ctx.tenant, %{
               "task" => "t1",
               "input_tokens" => 10,
               "output_tokens" => 20,
               "agent" => "alias-agent",
               "at" => "2026-09-05T10:00:00Z"
             })

    assert entry.tokens_in == nil
    assert entry.tokens_out == nil
    assert entry.agent_id == nil
    assert entry.updated_at == nil
  end

  test "a capped terminal entry cannot reappear through PubSub", ctx do
    for i <- 1..200 do
      assert {:ok, _} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "active-#{i}"})
    end

    Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Tracker.topic(ctx.tenant))

    assert {:ok, _} =
             Tracker.track(ctx.name, ctx.tenant, %{"task" => "discarded", "status" => "done"})

    assert_receive {:queue_removed, "discarded"}
    refute_receive {:queue_entry, %Entry{task: "discarded"}}, 50
    refute Enum.any?(Tracker.list(ctx.name, ctx.tenant), &(&1.task == "discarded"))
  end

  describe "tenancy" do
    test "one tenant never sees another tenant's workers", ctx do
      other = ctx.tenant <> "-other"
      {:ok, _} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "mine", "worker" => "crew-1"})
      {:ok, _} = Tracker.track(ctx.name, other, %{"task" => "theirs", "worker" => "crew-2"})

      assert [%Entry{task: "mine"}] = Tracker.list(ctx.name, ctx.tenant)
      assert [%Entry{task: "theirs"}] = Tracker.list(ctx.name, other)
    end

    test "an invalid slug never reaches the tracker", ctx do
      assert_raise ArgumentError, fn ->
        Tracker.track(ctx.name, "Not A Slug", %{"task" => "t1"})
      end
    end
  end

  describe "ordering" do
    test "work in flight sorts above work that has finished", ctx do
      {:ok, _} = Tracker.track(ctx.name, ctx.tenant, %{"task" => "finished", "status" => "done"})

      {:ok, _} =
        Tracker.track(ctx.name, ctx.tenant, %{"task" => "running", "status" => "working"})

      assert ["running", "finished"] == Enum.map(Tracker.list(ctx.name, ctx.tenant), & &1.task)
    end
  end

  describe "broadcasts" do
    test "a change reaches the tenant topic and a duplicate does not", ctx do
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Tracker.topic(ctx.tenant))

      {:ok, entry} =
        Tracker.track(ctx.name, ctx.tenant, %{"task" => "t1", "status" => "working"})

      assert_receive {:queue_entry, %Entry{task: "t1"}}

      # The node's own message coming back around from JetStream is a no-op.
      assert {:ok, ^entry} = Tracker.track(ctx.name, ctx.tenant, Entry.to_map(entry))
      refute_receive {:queue_entry, _}, 50
    end

    test "another tenant's traffic never reaches this topic", ctx do
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Tracker.topic(ctx.tenant))
      {:ok, _} = Tracker.track(ctx.name, ctx.tenant <> "-other", %{"task" => "theirs"})
      refute_receive {:queue_entry, _}, 50
    end
  end

  describe "retention" do
    test "finished work ages out of the look-in and the removal is announced", ctx do
      name = start_tracker(:"#{ctx.name}_sweep", 10)
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Tracker.topic(ctx.tenant))

      stale = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

      {:ok, _} =
        Tracker.track(name, ctx.tenant, %{
          "task" => "old",
          "status" => "done",
          "updated_at" => stale
        })

      assert_receive {:queue_removed, "old"}, 1_000
      assert Tracker.list(name, ctx.tenant) == []
    end

    test "work still in flight survives the sweep", ctx do
      name = start_tracker(:"#{ctx.name}_keep", 10)
      {:ok, _} = Tracker.track(name, ctx.tenant, %{"task" => "live", "status" => "working"})

      Process.sleep(40)
      assert [%Entry{task: "live"}] = Tracker.list(name, ctx.tenant)
    end
  end

  describe "wire form" do
    test "an entry round-trips through its published payload", ctx do
      {:ok, entry} =
        Tracker.track(ctx.name, ctx.tenant, %{
          "task" => "t1",
          "worker" => "crew-3",
          "agent_id" => "agent-abc",
          "model" => "claude-opus-5",
          "effort" => "high",
          "summary" => "port the queue view",
          "status" => "working",
          "tokens_in" => 10,
          "tokens_out" => 20
        })

      payload = entry |> Entry.to_map() |> Jason.encode!() |> Jason.decode!()

      assert payload["schema"] == Entry.schema()
      assert payload["tokens_total"] == 30
      assert {:ok, decoded} = Entry.new(ctx.tenant, payload)
      assert Entry.merge(nil, decoded) == entry
    end
  end
end
