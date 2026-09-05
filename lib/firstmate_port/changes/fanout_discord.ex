defmodule FirstmatePort.Changes.FanoutDiscord do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    kind = Keyword.fetch!(opts, :kind)

    Ash.Changeset.after_action(changeset, fn cs, record ->
      if notify?(cs) do
        %{kind: Atom.to_string(kind), id: record.id}
        |> FirstmatePort.Jobs.DiscordFanout.new()
        |> Oban.insert()
      end

      {:ok, record}
    end)
  end

  defp notify?(changeset) do
    case changeset.data do
      %{__meta__: %{state: :loaded}} ->
        Enum.any?([:title, :kind, :url, :status, :outcome, :step, :check_status], fn field ->
          Ash.Changeset.changing_attribute?(changeset, field)
        end)

      _ ->
        true
    end
  end
end
