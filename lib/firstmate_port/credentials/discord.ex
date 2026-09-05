defmodule FirstmatePort.Credentials.Discord do
  @moduledoc """
  Resolves a Discord interaction to the tenant that owns the app which signed it.

  Discord sends no tenant context. Verification considers every stored
  `discord`/`public_key` and succeeds only when exactly one tenant matches.
  Shared keys are allowed in storage but ambiguous signatures are unauthorized.
  Keys are read on every request, so portal rotation and deletion revoke them
  immediately. Environment keys are not accepted.
  """

  require Logger

  @provider "discord"
  @key "public_key"
  @signature_bytes 64
  @public_key_bytes 32

  @doc """
  Verifies a Discord signature and returns the tenant it belongs to.

  `{:ok, tenant_slug}` when exactly one tenant's key verifies `timestamp <> body`,
  `:error` otherwise.
  """
  def verify(signature, timestamp, body)
      when is_binary(signature) and is_binary(timestamp) and is_binary(body) do
    with {:ok, raw} <- decode_hex(signature),
         @signature_bytes <- byte_size(raw) do
      signed = timestamp <> body

      verification_keys()
      |> Enum.filter(fn {_tenant, public_key} ->
        :crypto.verify(:eddsa, :none, signed, raw, [public_key, :ed25519])
      end)
      |> Enum.map(fn {tenant, _public_key} -> tenant end)
      |> Enum.uniq()
      |> case do
        [tenant] -> {:ok, tenant}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  def verify(_signature, _timestamp, _body), do: :error

  @doc """
  Every usable tenant-stored `{tenant_slug, public_key}` pair.

  A malformed stored key is skipped and logged by slot, never by value, so one
  bad paste cannot take the endpoint down for other tenants.
  """
  def verification_keys do
    stored()
  end

  @doc "Whether any tenant has stored a Discord public key yet."
  def configured?, do: verification_keys() != []

  defp stored do
    @provider
    |> FirstmatePort.Credentials.slot_across_tenants(@key)
    |> Enum.flat_map(fn {tenant, hex} ->
      case public_key(hex) do
        {:ok, key} ->
          [{tenant, key}]

        :error ->
          Logger.warning(
            "tenant #{tenant} has an unusable #{@provider}/#{@key} credential; skipping it"
          )

          []
      end
    end)
  end

  defp public_key(hex) do
    case decode_hex(hex) do
      {:ok, raw} when byte_size(raw) == @public_key_bytes -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode_hex(hex) when is_binary(hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(_), do: :error
end
