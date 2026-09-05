defmodule FirstmatePort.Credentials.Validations.SlotValue do
  @moduledoc """
  Rejects a secret that cannot possibly work for its slot - a Discord public key
  that is not 64 hex characters, a blank token - so the failure surfaces in the
  portal instead of at the next inbound interaction.
  """

  use Ash.Resource.Validation

  alias FirstmatePort.Credentials.Slots

  @impl true
  def validate(changeset, _opts, _context) do
    with {:ok, value} when is_binary(value) <- Ash.Changeset.fetch_argument(changeset, :value),
         provider when is_binary(provider) <- provider(changeset),
         key when is_binary(key) <- key(changeset) do
      case Slots.validate_value(provider, key, String.trim(value)) do
        :ok ->
          :ok

        {:error, message} ->
          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :value,
             message: "#{provider}/#{key} #{message}"
           )}
      end
    else
      _ -> :ok
    end
  end

  defp provider(changeset), do: Ash.Changeset.get_attribute(changeset, :provider)
  defp key(changeset), do: Ash.Changeset.get_attribute(changeset, :key)
end
