defmodule FirstmatePort.Changes.AppendUsageSnapshot do
  @moduledoc """
  Appends a `FirstmatePort.Portal.UsageSnapshot` whenever a posted reading
  carries `used`. Posted readings are the only thing that feeds the ledger,
  so they are also the only thing that can give runway a burn rate.

  A post that only configures the account (allowance, window, spend
  priority) records nothing: the reading has to be present in the request,
  not merely defaulted.
  """
  use Ash.Resource.Change

  alias FirstmatePort.Portal.UsageSnapshot

  @impl true
  def change(changeset, _opts, context) do
    case posted_used(changeset) do
      nil ->
        changeset

      used ->
        Ash.Changeset.after_action(changeset, fn _changeset, account ->
          case UsageSnapshot.record(
                 %{usage_account_id: account.id, used: used},
                 actor: context.actor,
                 tenant: account.tenant_slug
               ) do
            {:ok, _snapshot} -> {:ok, account}
            {:error, error} -> {:error, error}
          end
        end)
    end
  end

  defp posted_used(changeset) do
    params = changeset.params || %{}

    if Map.has_key?(params, "used") or Map.has_key?(params, :used) do
      case Ash.Changeset.get_attribute(changeset, :used) do
        used when is_number(used) -> used * 1.0
        _ -> nil
      end
    end
  end
end
