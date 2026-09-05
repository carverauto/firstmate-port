defmodule FirstmatePort.Accounts.User.AssignDefaultTenant do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tenant_slug) do
      slug when is_binary(slug) and slug != "" ->
        if FirstmatePort.Tenancy.valid_slug?(slug) do
          changeset
        else
          Ash.Changeset.add_error(changeset, field: :tenant_slug, message: "invalid tenant slug")
        end

      _ ->
        Ash.Changeset.change_attribute(
          changeset,
          :tenant_slug,
          FirstmatePort.Tenancy.default_slug()
        )
    end
  end
end
