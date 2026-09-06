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
    changeset
    |> Ash.Changeset.before_action(&claim_existing/1)
    |> Ash.Changeset.after_action(fn changeset, item ->
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

  defp claim_existing(changeset) do
    url = Ash.Changeset.get_attribute(changeset, :url)

    if is_binary(url) and url != "" do
      case FirstmatePort.Repo.query(
             """
             SELECT p.* FROM progress_items p
             WHERE p.tenant_slug = $1 AND p.url = $2
             AND NOT EXISTS (
               SELECT 1 FROM progress_events e
               WHERE e.tenant_slug = p.tenant_slug AND e.item_id = p.id AND e.type = 'assignment'
             )
             FOR UPDATE OF p
             """,
             [changeset.tenant, url]
           ) do
        {:ok, %{columns: columns, rows: [row]}} ->
          item = FirstmatePort.Repo.load(FirstmatePort.Portal.ProgressItem, {columns, row})

          changeset
          |> Ash.Changeset.set_argument(
            :assigned_at,
            Ash.Changeset.get_argument(changeset, :assigned_at) || DateTime.utc_now()
          )
          |> Ash.Changeset.set_result({:ok, item})

        {:ok, %{rows: []}} ->
          changeset

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end
end

