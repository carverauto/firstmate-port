defmodule FirstmatePort.Portal.Changes.SeedAssignmentEvent do
  @moduledoc """
  Opens a progress item's log with the `:assignment` event that names the crew
  member whose work it is.

  This is what makes a Progress row crew work rather than a GitHub listing. The
  `:worker` argument on `:record` is required, so nothing can open a row without
  saying who is doing the thing — a mirror of an org's pull requests has no
  worker to name and therefore cannot create one.

  The append runs in the same transaction as the create, so a row can never
  exist without the event that explains why it exists.

  `:assigned_at` places that event in time. It defaults to the row's own
  `inserted_at`, which is right when the crew logs work as it happens, and can
  be set explicitly when firstmate backfills work that predates the log.
  """

  use Ash.Resource.Change

  alias FirstmatePort.Portal.ProgressEvent

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, item ->
      worker = Ash.Changeset.get_argument(changeset, :worker)

      attrs = %{
        item_id: item.id,
        type: :assignment,
        worker: worker,
        occurred_at: Ash.Changeset.get_argument(changeset, :assigned_at) || item.inserted_at
      }

      case ProgressEvent.append(attrs, Ash.Context.to_opts(context)) do
        {:ok, _event} -> {:ok, item}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
