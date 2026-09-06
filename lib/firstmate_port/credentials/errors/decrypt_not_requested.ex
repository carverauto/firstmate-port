defmodule FirstmatePort.Credentials.Errors.DecryptNotRequested do
  @moduledoc """
  Raised in place of a secret when a query loads an encrypted credential field
  without going through `FirstmatePort.Credentials`.
  """

  use Splode.Error, fields: [:field], class: :forbidden

  def message(%{field: field}) do
    """
    #{inspect(field)} was loaded without asking to decrypt it.

    Tenant secrets are read only through FirstmatePort.Credentials.secret/3 or
    slot_across_tenants/2, which is what keeps every HTTP path from returning one.
    """
  end
end
