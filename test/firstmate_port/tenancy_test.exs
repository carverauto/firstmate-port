defmodule FirstmatePort.TenancyTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Tenancy

  test "schema is prefixed from slug" do
    assert Tenancy.schema_for("local") == "t_local"
    assert Tenancy.schema(%{tenant_slug: "acme"}) == "t_acme"
    assert Tenancy.default_slug() == "local"
  end

  test "opts include actor and tenant schema" do
    actor = %{email: "a@localhost", tenant_slug: "local"}
    assert [actor: ^actor, tenant: "t_local"] = Tenancy.opts(actor)
  end
end
