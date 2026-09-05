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

  defp sign({_public, private}, timestamp, body) do
    :crypto.sign(:eddsa, :none, timestamp <> body, [private, :ed25519])
    |> Base.encode16(case: :lower)
  end

  test "the signing key selects the tenant" do
    alpha = :crypto.generate_key(:eddsa, :ed25519)
    beta = :crypto.generate_key(:eddsa, :ed25519)

    store_key(tenant("alpha"), alpha)
    store_key(tenant("beta"), beta)

    body = ~s({"type":2})
    ts = "1710000000"

    assert {:ok, "alpha"} = Discord.verify(sign(alpha, ts, body), ts, body)
    assert {:ok, "beta"} = Discord.verify(sign(beta, ts, body), ts, body)
  end

  test "a key nobody stored is unauthorized" do
    store_key(tenant("alpha"), :crypto.generate_key(:eddsa, :ed25519))

    stranger = :crypto.generate_key(:eddsa, :ed25519)
    body = ~s({"type":2})
    ts = "1710000000"

    assert :error = Discord.verify(sign(stranger, ts, body), ts, body)
  end

  test "a body signed for a different timestamp is unauthorized" do
    alpha = :crypto.generate_key(:eddsa, :ed25519)
    store_key(tenant("alpha"), alpha)

    body = ~s({"type":2})

    assert :error = Discord.verify(sign(alpha, "1710000000", body), "1710000001", body)
  end

  test "environment keys are never accepted, including after rotation and deletion" do
    {public, _} = original = :crypto.generate_key(:eddsa, :ed25519)
    Application.put_env(:firstmate_port, :discord_public_key, Base.encode16(public))
    body = ~s({"type":2})
    ts = "1710000000"

    refute Discord.configured?()
    assert :error = Discord.verify(sign(original, ts, body), ts, body)

    user = tenant("alpha")
    {:ok, credential} = store_key(user, original)
    assert {:ok, "alpha"} = Discord.verify(sign(original, ts, body), ts, body)

    {replacement_public, _} = replacement = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, rotated} =
      Credential.rotate(
        credential,
        %{value: Base.encode16(replacement_public)},
        Tenancy.opts(user)
      )

    assert :error = Discord.verify(sign(original, ts, body), ts, body)
    assert {:ok, "alpha"} = Discord.verify(sign(replacement, ts, body), ts, body)

    :ok = Credential.destroy(rotated, Tenancy.opts(user))
    assert :error = Discord.verify(sign(original, ts, body), ts, body)
    assert :error = Discord.verify(sign(replacement, ts, body), ts, body)
    refute Discord.configured?()
  end

  test "routing includes tenants beyond the first 200 keys" do
    for index <- 1..200 do
      store_key(tenant("tenant-#{index}"), :crypto.generate_key(:eddsa, :ed25519))
    end

    last = :crypto.generate_key(:eddsa, :ed25519)
    store_key(tenant("last"), last)
    body = ~s({"type":2})
    ts = "1710000000"

    assert {:ok, "last"} = Discord.verify(sign(last, ts, body), ts, body)

    {:ok, duplicate} = store_key(tenant("duplicate"), last)
    assert :error = Discord.verify(sign(last, ts, body), ts, body)
    :ok = Credential.destroy(duplicate, authorize?: false, tenant: "duplicate")
    assert {:ok, "last"} = Discord.verify(sign(last, ts, body), ts, body)
  end

  test "nothing configured verifies nothing" do
    refute Discord.configured?()
    assert :error = Discord.verify(String.duplicate("00", 64), "1", "{}")
  end

  test "a credential in another slot is not a Discord key" do
    {:ok, _} =
      Credential.create(
        %{provider: "shady", key: "public_key", value: "not-hex"},
        Tenancy.opts(tenant("alpha"))
      )

    refute Discord.configured?()
  end

  test "missing or malformed signature headers are unauthorized" do
    assert :error = Discord.verify(nil, "1", "{}")
    assert :error = Discord.verify("aa", nil, "{}")
    assert :error = Discord.verify("zz", "1", "{}")
  end
end
