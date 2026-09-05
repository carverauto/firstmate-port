defmodule FirstmatePort.Vault do
  @moduledoc """
  Cloak vault backing `AshCloak`. Every tenant credential is encrypted with this
  vault before it reaches Postgres, so CNPG only ever stores ciphertext.

  The key is the one secret the cluster still holds; tenant credentials are typed
  into the portal instead. See `docs/credentials.md`.

  Configured from the environment in `config/runtime.exs`:

    * `CLOAK_KEY` - base64 of 32 random bytes, used to encrypt new values. When
      it is unset, `config/runtime.exs` derives one from `SECRET_KEY_BASE` so a
      deployment that has not created the secret still boots.
      `deploy/bootstrap-secrets.sh` preserves that derived key when creating
      `firstmate-cloak`, keeping existing ciphertext readable.
    * `CLOAK_KEY_TAG` - the tag written into new ciphertext, `AES.GCM.V1` by
      default. Each key generation needs its own tag, because the tag is how a
      stored value finds the key that can read it.
    * `CLOAK_KEYS_RETIRED` - optional `tag=base64key` pairs, comma separated.
      Decrypt-only, so the active key can be replaced without a downtime
      re-encrypt: keep the old key here under its own tag, and give the new
      `CLOAK_KEY` a fresh `CLOAK_KEY_TAG`.

  See `docs/credentials.md` for the rotation procedure.
  """

  use Cloak.Vault, otp_app: :firstmate_port

  @default_tag "AES.GCM.V1"

  @impl GenServer
  def init(config) do
    {:ok, Keyword.put(config, :ciphers, ciphers(config))}
  end

  @doc "The tag new ciphertext is written with when none is configured."
  def default_tag, do: @default_tag

  defp ciphers(config) do
    case Keyword.get(config, :ciphers) do
      nil ->
        tag = Keyword.get(config, :tag) || @default_tag
        [{:default, aes_gcm(tag, key!(config))} | retired(config, tag)]

      ciphers ->
        ciphers
    end
  end

  defp retired(config, active_tag) do
    config
    |> Keyword.get(:retired_keys, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {{tag, key}, index} ->
      # Cloak picks the cipher by the tag stored in the ciphertext and takes the
      # first match, so a retired key sharing the active tag would never be
      # reached - and every value it wrote would be unreadable. Fail at boot
      # rather than at the first read.
      if tag == active_tag do
        raise ArgumentError,
              "retired cloak key reuses the active tag #{inspect(tag)}; " <>
                "give the new CLOAK_KEY a fresh CLOAK_KEY_TAG"
      end

      {:"retired_#{index}", aes_gcm(tag, decode_key!(key, "retired key #{tag}"))}
    end)
  end

  defp aes_gcm(tag, key) do
    {Cloak.Ciphers.AES.GCM, tag: tag, key: key, iv_length: 12}
  end

  defp key!(config) do
    case Keyword.get(config, :key) do
      nil ->
        raise """
        FirstmatePort.Vault has no encryption key. Set CLOAK_KEY to the base64 of
        32 random bytes: openssl rand -base64 32
        """

      key ->
        decode_key!(key, "CLOAK_KEY")
    end
  end

  defp decode_key!(key, label) when is_binary(key) do
    with {:ok, raw} <- Base.decode64(key),
         32 <- byte_size(raw) do
      raw
    else
      _ -> raise ArgumentError, "#{label} must be the base64 of exactly 32 bytes"
    end
  end
end
