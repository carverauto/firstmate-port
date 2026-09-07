defmodule FirstmatePort.Accounts.TenantTest do
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials.{Credential, Discord}
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

    test "occupied claims and live fallback claims have indistinguishable refusals" do
      default = Tenancy.default_slug()
      tenant(default)
      alpha = tenant("alpha")
      beta = tenant("beta")
      owner = human("beta")
      application_id = "100000000000000001"

      assert {:ok, _} = claim(alpha, application_id, human("alpha"))
      assert {:error, occupied} = claim(beta, application_id, owner)
      assert {:ok, "alpha"} = Discord.tenant_for(%{"application_id" => application_id})

      assert {:ok, %{discord_application_id: nil}} =
               Tenant.get_by_slug("beta", authorize?: false)

      store_default_key(human(default))
      unclaimed_id = "100000000000000002"
      assert {:ok, ^default} = Discord.tenant_for(%{"application_id" => unclaimed_id})
      assert {:error, fallback} = claim(beta, unclaimed_id, owner)
      assert refusal_messages(occupied) == ["Discord application claim is not permitted"]
      assert refusal_messages(fallback) == refusal_messages(occupied)
      assert {:ok, ^default} = Discord.tenant_for(%{"application_id" => unclaimed_id})
      assert {:ok, "alpha"} = Discord.tenant_for(%{"application_id" => application_id})

      assert {:ok, %{discord_application_id: nil}} =
               Tenant.get_by_slug("beta", authorize?: false)
    end

    test "the default tenant may claim and release while its key is stored" do
      default = Tenancy.default_slug()
      record = tenant(default)
      owner = human(default)
      store_default_key(owner)

      assert {:ok, claimed} = claim(record, "100000000000000001", owner)

      assert {:ok, ^default} =
               Discord.tenant_for(%{"application_id" => "100000000000000001"})

      assert {:ok, %{discord_application_id: nil}} = claim(claimed, nil, owner)
    end

    test "a refused replacement preserves an existing claim" do
      alpha = tenant("alpha")
      owner = human("alpha")
      assert {:ok, claimed} = claim(alpha, "100000000000000001", owner)
      tenant(Tenancy.default_slug())
      store_default_key(human(Tenancy.default_slug()))

      assert {:error, _} = claim(claimed, "100000000000000002", owner)

      assert {:ok, "alpha"} =
               Discord.tenant_for(%{"application_id" => "100000000000000001"})

      assert {:ok, %{discord_application_id: "100000000000000001"}} =
               Tenant.get_by_slug("alpha", authorize?: false)

      assert {:ok, %{discord_application_id: nil}} = claim(claimed, nil, owner)
    end
  end

  defp refusal_messages(error) do
    Enum.map(error.errors, & &1.message)
  end

  defp store_default_key(owner) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:ok, _} =
             Credential.create(
               %{provider: "discord", key: "public_key", value: Base.encode16(public)},
               Tenancy.opts(owner)
             )
  end
end
