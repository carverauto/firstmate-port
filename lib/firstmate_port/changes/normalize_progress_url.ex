defmodule FirstmatePort.Changes.NormalizeProgressUrl do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    kind = changeset |> Ash.Changeset.get_attribute(:kind) |> to_string()
    url = Ash.Changeset.get_attribute(changeset, :url)

    case FirstmatePort.Links.progress_url(kind, url) do
      {:ok, stored} ->
        Ash.Changeset.force_change_attribute(changeset, :url, stored)

      {:error, _} ->
        Ash.Changeset.add_error(changeset,
          field: :url,
          message: "must be a full https URL copied from GitHub"
        )
    end
  end
end
