defmodule FirstmatePort.Credentials.DiscordTest do
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials.{Credential, Discord}
  alias FirstmatePort.Tenancy

  setup do
    previous = Application.get_env(:firstmate_port, :discord_public_key)
    Application.put_env(:firstmate_port, :discord_public_key, nil)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_public_key, previous) end)
    :ok
  end

  defp tenant(slug) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{email: "#{slug}@example.com", name: slug, tenant_slug: slug},
        authorize?: false
      )

    user
  end

  defp store_key(user, {public, _private}) do
    {:ok, _} =
      Credential.create(
        %{provider: "discord", key: "public_key", value: Base.encode16(public, case: :lower)},
        Tenancy.opts(user)
      )
  end

  # Writes the encrypted row straight to Postgres, bypassing the slot validation,
  # to stand in for a credential this app did not write.
  defp store_row(slug, value) do
    {:ok, ciphertext} = FirstmatePort.Vault.encrypt(:erlang.term_to_binary(value))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      FirstmatePort.Repo.insert_all("tenant_credentials", [
        %{
          id: Ecto.UUID.dump!(Ash.UUIDv7.generate()),
          tenant_slug: slug,
          provider: "discord",
          key: "public_key",
          encrypted_value: Base.encode64(ciphertext),
          description: "",
          hint: "",
          value_bytes: byte_size(value),
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp sign({_public, private}, timestamp, body) do
    :crypto.sign(:eddsa, :none, timestamp <> body, [private, :ed25519])
    |> Base.encode16(case: :lower)
  end

  test "a tenant's own key verifies and no other tenant's does" do
    alpha = :crypto.generate_key(:eddsa, :ed25519)
    beta = :crypto.generate_key(:eddsa, :ed25519)

    store_key(tenant("alpha"), alpha)
    store_key(tenant("beta"), beta)

    body = ~s({"type":2})
    ts = "1710000000"

    assert Discord.verify?("alpha", sign(alpha, ts, body), ts, body)
    assert Discord.verify?("beta", sign(beta, ts, body), ts, body)

    refute Discord.verify?("beta", sign(alpha, ts, body), ts, body)
    refute Discord.verify?("alpha", sign(beta, ts, body), ts, body)
  end

  test "two tenants may hold the same app key without either speaking for the other" do
    shared = :crypto.generate_key(:eddsa, :ed25519)

    store_key(tenant("alpha"), shared)
    store_key(tenant("beta"), shared)

    body = ~s({"type":2})
    ts = "1710000000"
    signature = sign(shared, ts, body)

    # The hostname, not the key, decides who the interaction belongs to, so a
    # duplicated key is no longer an ambiguity that takes both tenants down.
    assert Discord.verify?("alpha", signature, ts, body)
    assert Discord.verify?("beta", signature, ts, body)
    refute Discord.verify?("gamma", signature, ts, body)
  end

  test "a key nobody stored is unauthorized" do
    store_key(tenant("alpha"), :crypto.generate_key(:eddsa, :ed25519))

    stranger = :crypto.generate_key(:eddsa, :ed25519)
    body = ~s({"type":2})
    ts = "1710000000"

    refute Discord.verify?("alpha", sign(stranger, ts, body), ts, body)
  end

  test "a tenant with no stored key verifies nothing" do
    tenant("alpha")
    key = :crypto.generate_key(:eddsa, :ed25519)
    body = ~s({"type":2})
    ts = "1710000000"

    refute Discord.configured?("alpha")
    refute Discord.verify?("alpha", sign(key, ts, body), ts, body)
  end

  test "a body signed for a different timestamp is unauthorized" do
    alpha = :crypto.generate_key(:eddsa, :ed25519)
    store_key(tenant("alpha"), alpha)

    body = ~s({"type":2})

    refute Discord.verify?("alpha", sign(alpha, "1710000000", body), "1710000001", body)
  end

  test "a body altered after signing is unauthorized" do
    alpha = :crypto.generate_key(:eddsa, :ed25519)
    store_key(tenant("alpha"), alpha)

    ts = "1710000000"
    signature = sign(alpha, ts, ~s({"type":2}))

    refute Discord.verify?("alpha", signature, ts, ~s({"type":3}))
  end

  test "environment keys are never accepted, including after rotation and deletion" do
    {public, _} = original = :crypto.generate_key(:eddsa, :ed25519)
    Application.put_env(:firstmate_port, :discord_public_key, Base.encode16(public))
    body = ~s({"type":2})
    ts = "1710000000"

    user = tenant("alpha")
    refute Discord.configured?("alpha")
    refute Discord.verify?("alpha", sign(original, ts, body), ts, body)

    {:ok, credential} = store_key(user, original)
    assert Discord.verify?("alpha", sign(original, ts, body), ts, body)

    {replacement_public, _} = replacement = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, rotated} =
      Credential.rotate(
        credential,
        %{value: Base.encode16(replacement_public)},
        Tenancy.opts(user)
      )

    refute Discord.verify?("alpha", sign(original, ts, body), ts, body)
    assert Discord.verify?("alpha", sign(replacement, ts, body), ts, body)

    :ok = Credential.destroy(rotated, Tenancy.opts(user))
    refute Discord.verify?("alpha", sign(original, ts, body), ts, body)
    refute Discord.verify?("alpha", sign(replacement, ts, body), ts, body)
    refute Discord.configured?("alpha")
  end

  test "the slot validation refuses a key that is not 64 hex characters" do
    assert {:error, error} =
             Credential.create(
               %{provider: "discord", key: "public_key", value: String.duplicate("ab", 16)},
               Tenancy.opts(tenant("alpha"))
             )

    assert Exception.message(error) =~ "must be 64 hex characters"
  end

  test "a stored key that is not a usable Ed25519 key is ignored, not fatal" do
    # The slot validation stops this at the form, so only a row written out of
    # band or before that check can look like this. It must still be inert
    # rather than take the endpoint down.
    user = tenant("alpha")
    store_row(user.tenant_slug, String.duplicate("zz", 32))

    refute Discord.configured?("alpha")
    refute Discord.verify?("alpha", String.duplicate("00", 64), "1710000000", "{}")
  end

  test "nothing configured verifies nothing" do
    refute Discord.configured?("local")
    refute Discord.verify?("local", String.duplicate("00", 64), "1", "{}")
  end

  test "a credential in another slot is not a Discord key" do
    {:ok, _} =
      Credential.create(
        %{provider: "shady", key: "public_key", value: "not-hex"},
        Tenancy.opts(tenant("alpha"))
      )

    refute Discord.configured?("alpha")
  end

  test "missing or malformed signature headers are unauthorized" do
    store_key(tenant("alpha"), :crypto.generate_key(:eddsa, :ed25519))

    refute Discord.verify?("alpha", nil, "1", "{}")
    refute Discord.verify?("alpha", "aa", nil, "{}")
    refute Discord.verify?("alpha", "zz", "1", "{}")
    refute Discord.verify?("alpha", String.duplicate("00", 63), "1", "{}")
  end
end
