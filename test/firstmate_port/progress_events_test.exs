defmodule FirstmatePort.ProgressEventsTest do
  use FirstmatePort.DataCase, async: true

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem}
  alias FirstmatePort.Tenancy

  test "patches append history and project without rewriting initial state" do
    {:ok, _} = Tenant.seed(%{slug: "events", name: "Events"}, authorize?: false)
    actor = %{role: :agent, tenant_slug: "events", email: "agent@localhost"}
    opts = Tenancy.opts(actor)
    {:ok, item} = ProgressItem.record(%{kind: :note, title: "Initial"}, opts)

    assert {:ok, first} =
             ProgressEvent.record(
               %{
                 item_id: item.id,
                 title: "Revised",
                 status: "working",
                 assignee: "firstmate",
                 extra_workers: ["secondmate"],
                 interruption: "waiting for review"
               },
               opts
             )

    assert {:ok, second} =
             ProgressEvent.record(
               %{
                 item_id: item.id,
                 kind: :achievement,
                 status: "done",
                 extra_workers: [],
                 interruption: ""
               },
               opts
             )

    assert second.id > first.id

    assert {:ok,
            [
              %{
                title: "Revised",
                kind: :achievement,
                status: "done",
                assignee: "firstmate",
                extra_workers: [],
                interruption: ""
              }
            ]} = ProgressItem.list(opts)

    assert %{rows: [["Initial", "note"]]} =
             FirstmatePort.Repo.query!(
               "SELECT title, kind FROM progress_items WHERE id = $1",
               [item.id]
             )

    assert {:ok, events} = ProgressEvent.list(opts)
    assert [persisted_first, persisted_second] = Enum.sort_by(events, & &1.id)

    assert {persisted_first.id, persisted_first.status, persisted_first.extra_workers} ==
             {first.id, "working", ["secondmate"]}

    assert {persisted_second.id, persisted_second.status} == {second.id, "done"}

    {:ok, _} = Tenant.seed(%{slug: "outsider", name: "Outsider"}, authorize?: false)
    outsider = %{actor | tenant_slug: "outsider"}

    assert {:error, _} =
             ProgressEvent.record(%{item_id: item.id, title: "stolen"}, Tenancy.opts(outsider))

    assert {:ok, []} = ProgressEvent.list(Tenancy.opts(outsider))
  end
end
