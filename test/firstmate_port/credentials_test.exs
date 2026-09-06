defmodule FirstmatePort.CredentialsTest do
  use FirstmatePort.DataCase, async: true

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Tenancy

  @discord_key String.duplicate("ab", 32)

  setup do
    {:ok, %{local: human("local", "local"), other: human("other", "other")}}
  end

  defp human(slug, label) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: label}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{
          email: "#{label}-#{System.unique_integer([:positive])}@example.com",
          name: label,
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  defp agent(slug) do
    {:ok, user} =
      User.bootstrap_agent(
        %{
          email: "agent-#{System.unique_integer([:positive])}@example.com",
          name: "agent",
          hashed_api_key: User.hash_token("token-#{System.unique_integer([:positive])}"),
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  describe "storing a secret" do
    test "round-trips through the vault", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "github", key: "token", value: "ghp_secret_value_123"},
          Tenancy.opts(local)
        )

      assert credential.tenant_slug == "local"
      assert {:ok, "ghp_secret_value_123"} = Credentials.secret(local, "github", "token")
    end

    test "leaves no plaintext in the column", %{local: local} do
      {:ok, _} =
        Credential.create(
          %{provider: "github", key: "token", value: "ghp_secret_value_123"},
          Tenancy.opts(local)
        )

      %{rows: [[stored]]} =
        Repo.query!("select encrypted_value from tenant_credentials limit 1", [])

      assert is_binary(stored)
      refute stored =~ "ghp_secret_value_123"
    end

    test "records a hint and size instead of the secret", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "github", key: "token", value: "  ghp_abcdefghij_wxyz  "},
          Tenancy.opts(local)
        )

      assert credential.hint == "wxyz"
      assert credential.value_bytes == byte_size("ghp_abcdefghij_wxyz")
      assert credential.rotated_at == nil
      assert {:ok, "ghp_abcdefghij_wxyz"} = Credentials.secret(local, "github", "token")
    end

    test "keeps no hint for a short secret", %{local: local} do
      {:ok, credential} =
        Credential.create(%{provider: "x", key: "y", value: "short"}, Tenancy.opts(local))

      assert credential.hint == ""
    end

    test "rejects a Discord public key that is not 64 hex characters", %{local: local} do
      assert {:error, error} =
               Credential.create(
                 %{provider: "discord", key: "public_key", value: "nope"},
                 Tenancy.opts(local)
               )

      assert Exception.message(error) =~ "64 hex characters"
    end

    test "rejects a second credential in the same slot", %{local: local} do
      {:ok, _} =
        Credential.create(%{provider: "github", key: "token", value: "one"}, Tenancy.opts(local))

      assert {:error, _} =
               Credential.create(
                 %{provider: "github", key: "token", value: "two"},
                 Tenancy.opts(local)
               )
    end
  end

  describe "rotation" do
    test "still checks the slot's shape", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "discord", key: "public_key", value: @discord_key},
          Tenancy.opts(local)
        )

      assert {:error, error} =
               Credential.rotate(credential, %{value: "nope"}, Tenancy.opts(local))

      assert FirstmatePort.Credentials.Errors.describe(error) =~ "64 hex characters"
      assert {:ok, @discord_key} = Credentials.secret(local, "discord", "public_key")
    end

    test "leaves the note alone when only the secret changes", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "github", key: "token", value: "first_value_here", description: "ci"},
          Tenancy.opts(local)
        )

      {:ok, rotated} =
        Credential.rotate(credential, %{value: "second_value_here"}, Tenancy.opts(local))

      assert rotated.description == "ci"
    end
  end

  describe "put/2" do
    test "creates then rotates the same slot", %{local: local} do
      {:ok, created} =
        Credentials.put(
          %{provider: "github", key: "token", value: "first_value_here", description: "ci"},
          Tenancy.opts(local)
        )

      assert created.rotated_at == nil

      {:ok, rotated} =
        Credentials.put(
          %{provider: "github", key: "token", value: "second_value_here", description: ""},
          Tenancy.opts(local)
        )

      assert rotated.id == created.id
      assert rotated.rotated_at
      assert rotated.hint == "here"
      assert {:ok, "second_value_here"} = Credentials.secret(local, "github", "token")
    end
  end

  describe "tenancy" do
    test "one tenant cannot list another's credentials", %{local: local, other: other} do
      {:ok, _} =
        Credential.create(
          %{provider: "github", key: "token", value: "local-only"},
          Tenancy.opts(local)
        )

      assert {:ok, [%Credential{provider: "github"}]} = Credential.list(Tenancy.opts(local))
      assert {:ok, []} = Credential.list(Tenancy.opts(other))
      assert {:ok, nil} = Credential.get_slot("github", "token", Tenancy.opts(other))
    end

    test "an actor cannot read a slot by asking for another tenant", %{local: local, other: other} do
      {:ok, _} =
        Credential.create(
          %{provider: "github", key: "token", value: "local-only"},
          Tenancy.opts(local)
        )

      # Even with the other tenant's slug forced onto the query, the read policy
      # filters to the actor's own tenant.
      assert {:ok, []} = Credential.list(actor: other, tenant: "local")
    end

    test "agents cannot write credentials", %{local: _local} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Credential.create(
                 %{provider: "github", key: "token", value: "from-an-agent"},
                 Tenancy.opts(agent("local"))
               )
    end

    test "agents can still list their tenant's slots", %{local: local} do
      {:ok, _} =
        Credential.create(
          %{provider: "github", key: "token", value: "local-only"},
          Tenancy.opts(local)
        )

      assert {:ok, [%Credential{}]} = Credential.list(Tenancy.opts(agent("local")))
    end
  end

  describe "decryption" do
    test "a plain load of :value is refused", %{local: local} do
      {:ok, _} =
        Credential.create(
          %{provider: "github", key: "token", value: "local-only"},
          Tenancy.opts(local)
        )

      assert {:error, error} =
               Credential.get_slot("github", "token", Tenancy.opts(local, load: [:value]))

      assert Exception.message(error) =~ "without asking to decrypt it"
    end

    test "a secret is only ever read for the tenant that owns it", %{local: local, other: other} do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      key = Base.encode16(public)

      {:ok, _} =
        Credential.create(
          %{provider: "discord", key: "public_key", value: key},
          Tenancy.opts(local)
        )

      assert {:ok, ^key} = Credentials.secret(local, "discord", "public_key")
      assert :error = Credentials.secret(other, "discord", "public_key")

      signature =
        :crypto.sign(:eddsa, :none, "1{}", [private, :ed25519])
        |> Base.encode16()

      assert Credentials.Discord.verify?("local", signature, "1", "{}")
      refute Credentials.Discord.verify?("other", signature, "1", "{}")
    end

    test "an empty slot reads as :error", %{local: local} do
      assert :error = Credentials.secret(local, "github", "token")
    end
  end

  describe "audit versions" do
    test "never carry the ciphertext", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "github", key: "token", value: "first_value_here"},
          Tenancy.opts(local)
        )

      {:ok, _} =
        Credential.rotate(credential, %{value: "second_value_here"}, Tenancy.opts(local))

      %{rows: rows} = Repo.query!("select changes from tenant_credentials_versions", [])

      assert length(rows) == 2

      for [changes] <- rows do
        refute Map.has_key?(changes, "encrypted_value")
        refute inspect(changes) =~ "first_value_here"
        refute inspect(changes) =~ "second_value_here"
      end
    end

    test "record who acted and under which action", %{local: local} do
      {:ok, credential} =
        Credential.create(
          %{provider: "github", key: "token", value: "first_value_here"},
          Tenancy.opts(local)
        )

      {:ok, _} =
        Credential.rotate(credential, %{value: "second_value_here"}, Tenancy.opts(local))

      %{rows: rows} =
        Repo.query!(
          "select version_action_name, user_id from tenant_credentials_versions order by version_inserted_at",
          []
        )

      actor_id = Ecto.UUID.dump!(local.id)
      assert [["create", ^actor_id], ["rotate", ^actor_id]] = rows
    end
  end
end
