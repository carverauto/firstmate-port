defmodule FirstmatePort.Jobs.FleetSyncChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, record ->
      case FirstmatePort.Jobs.FleetIndex.sync() do
        :ok -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
