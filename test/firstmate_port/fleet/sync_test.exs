defmodule FirstmatePort.Fleet.SyncTest do
  use FirstmatePort.DataCase, async: false

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Fleet.{Document, Sync}
  alias FirstmatePort.Portal.ProgressEvent
  alias FirstmatePort.Tenancy

  setup do
    FirstmatePort.Test.AppConfig.put_env(:build_tracking, kubernetes_enabled: true)
    tenant("local")
    {:ok, actor: agent("local")}
  end

  test "one sync projects every source the fleet log has", %{actor: actor} do
    github_item(actor, %{title: "Rework the roll job"})
    progress_item(actor, %{title: "Shipped the search box"})
    roll(actor, %{outcome: "web-ng rolled"})
    no_mistakes_run(actor, %{findings: "one finding"})
    diagram(actor, %{title: "Runtime modes"})

    assert {:ok, %{scanned: 5, written: 5, removed: 0}} = Sync.run("local")

    assert {:ok, documents} = Document.list(Tenancy.opts(actor))

    assert [:diagram, :github_item, :no_mistakes_run, :progress_item, :roll] =
             documents |> Enum.map(& &1.source) |> Enum.sort()
  end

  test "a second sync writes nothing", %{actor: actor} do
    github_item(actor)

    assert {:ok, %{written: 1}} = Sync.run("local")
    assert {:ok, %{scanned: 1, written: 0, removed: 0}} = Sync.run("local")
  end

  test "a changed record is reprojected in place", %{actor: actor} do
    item = progress_item(actor, %{title: "Before"})
    assert {:ok, %{written: 1}} = Sync.run("local")

    {:ok, _} =
      ProgressEvent.record(
        %{item_id: item.id, kind: :note, title: "After"},
        Tenancy.opts(actor)
      )

    assert {:ok, %{scanned: 1, written: 1}} = Sync.run("local")

    assert {:ok, [%Document{title: "After", source_id: source_id}]} =
             Document.list(Tenancy.opts(actor))

    assert source_id == item.id
  end

  test "a document whose record has gone is removed", %{actor: actor} do
    {:ok, orphan} =
      Document.upsert(
        %{
          source: :progress_item,
          source_id: "vanished",
          title: "Was here",
          url: "",
          body: "",
          document: %{},
          search_text: "title: Was here",
          content_hash: "deadbeef",
          occurred_at: DateTime.utc_now()
        },
        Tenancy.opts(actor)
      )

    assert {:ok, %{removed: 1}} = Sync.run("local")

    assert {:ok, []} = Document.list(Tenancy.opts(actor))
    assert orphan.source_id == "vanished"
  end

  test "a tenant only ever sees its own log" do
    tenant("other")
    local = agent("local")
    other = agent("other")

    progress_item(local, %{title: "Local only"})
    progress_item(other, %{title: "Other only"})

    assert {:ok, %{written: 1}} = Sync.run("local")
    assert {:ok, %{written: 1}} = Sync.run("other")

    assert {:ok, [%Document{title: "Local only"}]} = Document.list(Tenancy.opts(local))
    assert {:ok, [%Document{title: "Other only"}]} = Document.list(Tenancy.opts(other))
  end

  test "the projection carries the record's JSON, not just its title", %{actor: actor} do
    roll(actor, %{image_tag: "sha-cafe", outcome: "rolled"})

    assert {:ok, %{written: 1}} = Sync.run("local")

    assert {:ok, [%Document{document: document}]} = Document.list(Tenancy.opts(actor))
    assert %{"image_tag" => "sha-cafe", "cluster" => "farm01", "outcome" => "rolled"} = document
  end

  test "sync persists changes beyond the searchable text window", %{actor: actor} do
    long = String.duplicate("x", 2_000)
    run = no_mistakes_run(actor, %{branch: long, findings: long, intent: long, outcome: long})
    assert {:ok, %{written: 1}} = Sync.run("local")
    {:ok, [before]} = Document.list(Tenancy.opts(actor))

    captain = human("local")

    {:ok, updated} =
      FirstmatePort.Portal.NoMistakesRun.human_respond(
        run,
        %{respond_instructions: "Please fix the finding"},
        Tenancy.opts(captain)
      )

    assert {:ok, %{written: 1}} = Sync.run("local")
    assert {:ok, [after_change]} = Document.list(Tenancy.opts(actor))
    assert after_change.id == before.id
    assert after_change.search_text == before.search_text
    assert after_change.document["respond_instructions"] == "Please fix the finding"
    assert after_change.occurred_at == updated.updated_at
    assert {:ok, %{written: 0}} = Sync.run("local")
  end
end
