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

  test "the bootstrap env key resolves to the default tenant" do
    {public, _} = keypair = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:firstmate_port, :discord_public_key, Base.encode16(public, case: :lower))

    body = ~s({"type":1})
    ts = "1710000000"

    assert {:ok, "local"} = Discord.verify(sign(keypair, ts, body), ts, body)
  end

  test "a tenant's stored key works alongside the bootstrap key" do
    {bootstrap_public, _} = bootstrap = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(
      :firstmate_port,
      :discord_public_key,
      Base.encode16(bootstrap_public, case: :lower)
    )

    stored = :crypto.generate_key(:eddsa, :ed25519)
    store_key(tenant("alpha"), stored)

    body = ~s({"type":2})
    ts = "1710000000"

    # Each resolves to its own tenant: bootstrapping never locks a tenant out,
    # and a tenant storing a key never breaks the bootstrap path.
    assert {:ok, "alpha"} = Discord.verify(sign(stored, ts, body), ts, body)
    assert {:ok, "local"} = Discord.verify(sign(bootstrap, ts, body), ts, body)
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
