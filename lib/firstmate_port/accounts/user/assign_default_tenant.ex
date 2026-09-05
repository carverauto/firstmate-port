defmodule FirstmatePort.Accounts.User.AssignDefaultTenant do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tenant_slug) do
      slug when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        Ash.Changeset.change_attribute(
          changeset,
          :tenant_slug,
          FirstmatePort.Tenancy.default_slug()
        )
    end
  end
end
