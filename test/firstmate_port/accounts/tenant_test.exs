defmodule FirstmatePort.Accounts.TenantTest do
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Tenancy

  defp tenant(slug) do
    {:ok, record} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)
    record
  end

  defp human(slug) do
    {:ok, user} =
      User.upsert_oidc(%{email: "#{slug}@example.com", name: slug, tenant_slug: slug},
        authorize?: false
      )

    user
  end

  defp agent(slug) do
    {:ok, user} =
      User.bootstrap_agent(
        %{
          email: "agent-#{slug}@example.com",
          name: "agent #{slug}",
          hashed_api_key: User.hash_token("token-#{slug}"),
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  defp claim(record, application_id, actor) do
    Tenant.claim_discord_application(
      record,
      %{discord_application_id: application_id},
      Tenancy.opts(actor)
    )
  end

  describe "claiming a Discord application" do
    test "the people who own the tenant may claim and release it" do
      record = tenant("alpha")
      owner = human("alpha")

      assert {:ok, claimed} = claim(record, "100000000000000001", owner)
      assert claimed.discord_application_id == "100000000000000001"

      assert {:ok, released} = claim(claimed, nil, owner)
      assert released.discord_application_id == nil
    end

    test "an agent API key cannot claim one" do
      record = tenant("alpha")

      assert {:error, error} = claim(record, "100000000000000001", agent("alpha"))
      assert %Ash.Error.Forbidden{} = error
    end

    test "another tenant's owner cannot claim one" do
      record = tenant("alpha")
      tenant("beta")

      assert {:error, error} = claim(record, "100000000000000001", human("beta"))
      assert %Ash.Error.Forbidden{} = error
    end

    test "nobody at all cannot claim one" do
      record = tenant("alpha")

      assert {:error, %Ash.Error.Forbidden{}} =
               Tenant.claim_discord_application(record, %{
                 discord_application_id: "100000000000000001"
               })
    end

    test "an application id that is not a snowflake is refused" do
      record = tenant("alpha")
      owner = human("alpha")

      for junk <- ["not-a-number", "12345678901234567890123456789012345", "12 34", "0x1f"] do
        assert {:error, _} = claim(record, junk, owner), "#{junk} was accepted"
      end
    end

    test "two tenants cannot hold the same claim" do
      alpha = tenant("alpha")
      beta = tenant("beta")

      assert {:ok, _} = claim(alpha, "100000000000000001", human("alpha"))
      assert {:error, _} = claim(beta, "100000000000000001", human("beta"))
    end
  end
end
