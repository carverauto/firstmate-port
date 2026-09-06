defmodule FirstmatePort.QueueEntryTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Queues.Entry

  defp seed(params) do
    {:ok, report} = Entry.new("local", Map.put(params, "task", "t1"))
    Entry.merge(nil, report)
  end

  defp decode(entry) do
    {:ok, report} = Entry.new("local", Entry.to_report(entry))
    report
  end

  test "another node's sparse report preserves known status and original start time" do
    working =
      seed(%{
        "status" => "working",
        "started_at" => "2026-09-05T09:00:00Z",
        "updated_at" => "2026-09-05T10:00:00Z",
        "tokens_in" => 100,
        "tokens_out" => 50
      })

    sparse =
      seed(%{
        "tokens_in" => 10,
        "tokens_out" => 60,
        "updated_at" => "2026-09-05T10:01:00Z"
      })

    payload = Entry.to_report(sparse)
    refute Map.has_key?(payload, "status")
    refute Map.has_key?(payload, "started_at")
    assert sparse.status == :queued
    assert sparse.started_at == sparse.updated_at

    for report <- [sparse, decode(sparse)] do
      merged = Entry.merge(working, report)
      assert merged.status == :working
      assert merged.started_at == working.started_at
      assert merged.tokens_in == 100
      assert merged.tokens_out == 60
      assert Entry.merge(merged, decode(merged)) == merged
    end
  end

  test "defaulted entries remain identical after their own wire report returns" do
    for status <- [nil, "working", "done"] do
      entry = seed(%{"status" => status, "updated_at" => "2026-09-05T10:00:00Z"})
      assert Entry.merge(entry, decode(entry)) == entry
      assert Entry.merge(nil, decode(entry)) == entry
    end
  end

  test "explicit reports replace defaults and are retained on publication" do
    prior = seed(%{"updated_at" => "2026-09-05T10:00:00Z"})

    {:ok, report} =
      Entry.new("local", %{
        "task" => "t1",
        "status" => "working",
        "started_at" => "2026-09-05T09:00:00Z",
        "updated_at" => "2026-09-05T10:01:00Z"
      })

    entry = Entry.merge(prior, report)
    assert Entry.to_report(entry)["status"] == "working"
    assert Entry.to_report(entry)["started_at"] == "2026-09-05T09:00:00Z"
    assert Entry.merge(entry, decode(entry)) == entry
  end

  test "sparse reports preserve a terminal status and stop time" do
    done = seed(%{"status" => "done", "updated_at" => "2026-09-05T10:00:00Z"})
    sparse = seed(%{"tokens_in" => 100, "updated_at" => "2026-09-05T10:01:00Z"})
    merged = Entry.merge(done, decode(sparse))
    assert merged.status == :done
    assert merged.started_at == done.started_at
    assert merged.stopped_at == done.stopped_at
    assert merged.tokens_in == 100
    assert Entry.merge(merged, decode(merged)) == merged
  end
end
