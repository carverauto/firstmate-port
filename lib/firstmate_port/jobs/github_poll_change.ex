defmodule FirstmatePort.Jobs.GitHubPollChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _cs, record ->
      :ok = FirstmatePort.Jobs.GitHubPoll.run(context.actor)
      {:ok, record}
    end)
  end
end
