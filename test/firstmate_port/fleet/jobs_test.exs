defmodule FirstmatePort.Fleet.JobsTest do
  use FirstmatePort.DataCase, async: false

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Fleet.Document
  alias FirstmatePort.Jobs.Tick
  alias FirstmatePort.Tenancy

  setup do
    tenant("local")
    {:ok, actor: agent("local")}
  end

  test "the scheduled sync action projects the log", %{actor: actor} do
    progress_item(actor, %{title: "scheduled work"})

    assert :ok = scheduled(:fleet_sync)

    assert {:ok, [%Document{title: "scheduled work"}]} = Document.list(Tenancy.opts(actor))
  end

  test "the scheduled embed action is a no-op when nothing is configured", %{actor: actor} do
    progress_item(actor, %{title: "unconfigured"})
    :ok = scheduled(:fleet_sync)

    assert :ok = scheduled(:fleet_embed)

    assert {:ok, [%Document{embedded_at: nil}]} = Document.list(Tenancy.opts(actor))
  end

  test "a sync covers every tenant, not just the default one" do
    tenant("other")
    other = agent("other")
    progress_item(other, %{title: "other tenant work"})

    assert :ok = scheduled(:fleet_sync)

    assert {:ok, [%Document{title: "other tenant work"}]} = Document.list(Tenancy.opts(other))
  end
  defp scheduled(action) do
    Tick
    |> Ash.ActionInput.new()
    |> Ash.ActionInput.for_action(action, %{}, authorize?: false)
    |> Ash.run_action!()
  end

end
