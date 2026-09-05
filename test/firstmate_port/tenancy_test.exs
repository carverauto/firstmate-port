defmodule FirstmatePort.TenancyTest do
  use FirstmatePort.DataCase, async: true

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Portal.ProgressItem
  alias FirstmatePort.Tenancy

  test "opts pass the slug as the Ash tenant" do
    actor = %{email: "a@localhost", tenant_slug: "local"}
    assert [actor: ^actor, tenant: "local"] = Tenancy.opts(actor)
    assert Tenancy.default_slug() == "local"
  end

  test "invalid slugs error instead of reading the default tenant" do
    assert_raise ArgumentError, fn -> Tenancy.slug(%{tenant_slug: "Acme.Steer.>"}) end
    assert_raise ArgumentError, fn -> Tenancy.slug("not a slug") end
  end

  test "upsert rejects an invalid tenant slug" do
    assert {:error, _} =
             FirstmatePort.Accounts.User.upsert_oidc(
               %{email: "bad-tenant@localhost", name: "Bad", tenant_slug: "Acme"},
               authorize?: false
             )
  end

  test "streams are named <tenant>.steer and <tenant>.inbound" do
    assert Tenancy.steer_stream("acme") == "acme.steer"
    assert Tenancy.inbound_stream("acme") == "acme.inbound"
    assert Tenancy.steer_subjects("acme") == ["acme.steer.>"]
    assert Tenancy.inbound_subjects("acme") == ["acme.discord.inbound"]
    refute "acme.>" in Tenancy.steer_subjects("acme")
    refute "acme.>" in Tenancy.inbound_subjects("acme")
  end

  test "one tenant cannot read another tenant's rows" do
    {:ok, _} = Tenant.seed(%{slug: "acme", name: "Acme"}, authorize?: false)
    {:ok, _} = Tenant.seed(%{slug: "beta", name: "Beta"}, authorize?: false)

    acme = %{role: :agent, email: "acme@localhost", tenant_slug: "acme"}
    beta = %{role: :agent, email: "beta@localhost", tenant_slug: "beta"}

    assert {:ok, _} =
             ProgressItem.record(
               %{kind: :note, title: "acme secret", url: "", body: ""},
               Tenancy.opts(acme)
             )

    assert {:ok, _} =
             ProgressItem.record(
               %{kind: :note, title: "beta secret", url: "", body: ""},
               Tenancy.opts(beta)
             )

    assert {:ok, acme_items} = ProgressItem.list(Tenancy.opts(acme))
    assert {:ok, beta_items} = ProgressItem.list(Tenancy.opts(beta))

    assert [%{title: "acme secret"}] = acme_items
    assert [%{title: "beta secret"}] = beta_items
    refute Enum.any?(acme_items, &(&1.title == "beta secret"))
    refute Enum.any?(beta_items, &(&1.title == "acme secret"))
  end
end
