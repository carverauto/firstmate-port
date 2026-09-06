defmodule FirstmatePort.VaultTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Vault

  defp key, do: Base.encode64(:crypto.strong_rand_bytes(32))

  defp ciphers(config) do
    {:ok, config} = Vault.init(config)
    Keyword.fetch!(config, :ciphers)
  end

  test "encrypts with the active key and reads back what a retired key wrote" do
    old = key()
    new = key()

    old_config = ciphers(key: old)
    {:default, {module, opts}} = List.keyfind(old_config, :default, 0)
    {:ok, written_before_rotation} = module.encrypt("s3cret", opts)

    rotated = ciphers(key: new, tag: "AES.GCM.V2", retired_keys: [{"AES.GCM.V1", old}])

    assert [{:default, _}, {:retired_1, _}] = rotated
    assert {:ok, "s3cret"} = Cloak.Vault.decrypt([ciphers: rotated], written_before_rotation)

    # New writes use the new key, and the retired key cannot read them.
    {:default, {^module, new_opts}} = List.keyfind(rotated, :default, 0)
    {:ok, written_after_rotation} = module.encrypt("s3cret", new_opts)
    assert {:ok, "s3cret"} = Cloak.Vault.decrypt([ciphers: rotated], written_after_rotation)
    assert {:error, _} = Cloak.Vault.decrypt([ciphers: old_config], written_after_rotation)
  end

  test "refuses a retired key that would shadow the active one" do
    shared = key()

    assert_raise ArgumentError, ~r/reuses the active tag/, fn ->
      ciphers(key: shared, retired_keys: [{"AES.GCM.V1", key()}])
    end
  end

  test "refuses a key that is not 32 bytes" do
    assert_raise ArgumentError, ~r/exactly 32 bytes/, fn ->
      ciphers(key: Base.encode64("too short"))
    end
  end

  test "refuses to start with no key at all" do
    assert_raise RuntimeError, ~r/no encryption key/, fn -> ciphers([]) end
  end

  test "the running vault round-trips a value" do
    assert {:ok, "round trip"} = Vault.decrypt(Vault.encrypt!("round trip"))
  end
end
