defmodule FirstmatePort.Credentials.Changes.PrepareSecret do
  @moduledoc """
  Normalises the `:value` argument before `AshCloak` encrypts it, and records the
  non-secret facts the portal shows in its place: the last four characters and
  the byte size.

  Runs at change time so the trimmed argument is what AshCloak's `before_action`
  hook picks up.
  """

  use Ash.Resource.Change

  alias FirstmatePort.Credentials.Slots

  @impl true
  def change(changeset, opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :value) do
      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        changeset
        |> Ash.Changeset.set_argument(:value, trimmed)
        |> Ash.Changeset.force_change_attribute(:hint, Slots.hint(trimmed))
        |> Ash.Changeset.force_change_attribute(:value_bytes, byte_size(trimmed))
        |> stamp_rotation(opts)

      _ ->
        changeset
    end
  end

  defp stamp_rotation(changeset, opts) do
    if opts[:rotation?] do
      Ash.Changeset.force_change_attribute(changeset, :rotated_at, DateTime.utc_now())
    else
      changeset
    end
  end
end
