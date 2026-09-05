defmodule FirstmatePort.Changes.AssignPublicId do
  @moduledoc false
  use Ash.Resource.Change

  @alphabet ~c"abcdefghijkmnpqrstuvwxyz23456789"

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :id) do
      id when is_binary(id) and id != "" ->
        changeset

      _ ->
        Ash.Changeset.force_change_attribute(changeset, :id, generate())
    end
  end

  def generate do
    bytes = :crypto.strong_rand_bytes(10)

    for <<b <- bytes>>, into: "" do
      <<Enum.at(@alphabet, rem(b, length(@alphabet)))>>
    end
  end
end
