defmodule FirstmatePort.Credentials.Discord do
  @moduledoc """
  Verifies a Discord interaction against one tenant's stored public key.

  The tenant is decided before verification, by the hostname Discord posted to
  (see `FirstmatePort.Tenancy.DiscordHost`), so a request is only ever checked
  against the key of the tenant it was addressed to. No other tenant's key is
  read, tried, or reported on, which is what keeps one tenant's interactions
  from being verified - or published - by another.

  Keys come from the tenant credential store and are read on every request, so
  storing, rotating, or deleting a key in the portal takes effect immediately.
  Environment keys are not accepted.
  """

  require Logger

  @provider "discord"
  @key "public_key"
  @signature_bytes 64
  @public_key_bytes 32

  @doc """
  Whether `signature` is `tenant`'s Ed25519 signature over `timestamp <> body`.

  True only when the tenant has a usable stored key and that key verifies the
  raw request body exactly as received. A tenant with no key, or an unusable
  one, verifies nothing.
  """
  def verify?(tenant, signature, timestamp, body)
      when is_binary(signature) and is_binary(timestamp) and is_binary(body) do
    with {:ok, raw} <- decode_hex(signature),
         @signature_bytes <- byte_size(raw),
         {:ok, public_key} <- public_key(tenant) do
      :crypto.verify(:eddsa, :none, timestamp <> body, raw, [public_key, :ed25519])
    else
      _ -> false
    end
  end

  def verify?(_tenant, _signature, _timestamp, _body), do: false

  @doc """
  The tenant's stored Discord public key as raw bytes.

  `:error` when the tenant has not filled the slot or the stored value is not a
  32-byte hex key. A malformed key is logged by tenant and slot, never by value.
  """
  def public_key(tenant) do
    case FirstmatePort.Credentials.secret(tenant, @provider, @key) do
      {:ok, hex} -> decode_public_key(tenant, hex)
      _ -> :error
    end
  end

  @doc "Whether `tenant` has stored a usable Discord public key."
  def configured?(tenant), do: match?({:ok, _}, public_key(tenant))

  defp decode_public_key(tenant, hex) do
    case decode_hex(hex) do
      {:ok, raw} when byte_size(raw) == @public_key_bytes ->
        {:ok, raw}

      _ ->
        Logger.warning(
          "tenant #{tenant} has an unusable #{@provider}/#{@key} credential; ignoring it"
        )

        :error
    end
  end

  defp decode_hex(hex) when is_binary(hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(_), do: :error
end
