defmodule FirstmatePort.Jobs.RetentionChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, record ->
      FirstmatePort.Jobs.Retention.run()
      {:ok, record}
    end)
  end
end
