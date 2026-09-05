defmodule FirstmatePort.Credentials.Discord do
  @moduledoc """
  Resolves a Discord interaction to the tenant that owns the app which signed it.

  Discord sends no tenant context, but every interaction is signed with the
  application's Ed25519 key - and each tenant stores its own key in the
  `discord`/`public_key` slot. So the signature itself picks the tenant: we try
  the stored keys, and the one that verifies names the owner. Failing to verify
  against any key is an unauthorized request, exactly as before.

  ## Bootstrap

  Before any tenant has filled the slot - a fresh install, or local development -
  `DISCORD_PUBLIC_KEY` still works and resolves to the default tenant. It is
  checked last, so a tenant that stores its own key immediately takes over
  without an environment change or a redeploy. Nothing needs a
  `kubectl create secret firstmate-discord`.
  """

  require Logger

  @provider "discord"
  @key "public_key"
  @signature_bytes 64
  @public_key_bytes 32

  @doc """
  Verifies a Discord signature and returns the tenant it belongs to.

  `{:ok, tenant_slug}` when some configured key verifies `timestamp <> body`,
  `:error` otherwise.
  """
  def verify(signature, timestamp, body)
      when is_binary(signature) and is_binary(timestamp) and is_binary(body) do
    with {:ok, raw} <- decode_hex(signature),
         @signature_bytes <- byte_size(raw) do
      signed = timestamp <> body

      Enum.find_value(verification_keys(), :error, fn {tenant, public_key} ->
        if :crypto.verify(:eddsa, :none, signed, raw, [public_key, :ed25519]) do
          {:ok, tenant}
        end
      end)
    else
      _ -> :error
    end
  end

  def verify(_signature, _timestamp, _body), do: :error

  @doc """
  Every usable `{tenant_slug, public_key}` pair, tenant-stored keys first.

  A malformed stored key is skipped and logged by slot, never by value, so one
  bad paste cannot take the endpoint down for other tenants.
  """
  def verification_keys do
    stored() ++ bootstrap()
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

  defp bootstrap do
    case Application.get_env(:firstmate_port, :discord_public_key) do
      hex when is_binary(hex) and hex != "" ->
        case public_key(hex) do
          {:ok, key} -> [{FirstmatePort.Tenancy.default_slug(), key}]
          :error -> []
        end

      _ ->
        []
    end
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
