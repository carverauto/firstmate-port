defmodule FirstmatePort.Events.AdvisoryLockKey do
  @moduledoc "Advisory lock keys from string tenant slugs (AshEvents default only handles int/uuid)."

  use AshEvents.AdvisoryLockKeyGenerator

  @impl true
  def generate_key!(changeset, default_integer) do
    case changeset.tenant do
      slug when is_binary(slug) and slug != "" ->
        <<hi::signed-32, lo::signed-32, _rest::binary>> = :crypto.hash(:sha256, slug)
        [hi, lo]

      _ ->
        default_integer
    end
  end
end
