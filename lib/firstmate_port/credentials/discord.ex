defmodule FirstmatePort.Credentials.Discord do
  @moduledoc """
  Decides which tenant an inbound Discord interaction belongs to, and verifies
  it against that tenant's stored public key.

  One interactions URL serves every tenant. Discord names the application it is
  calling for in the payload, so `application_id` is what selects the tenant:
  whoever claimed that application (see
  `FirstmatePort.Accounts.Tenant`) is the tenant whose key the request is
  checked against, and no other tenant's key is read, tried, or reported on.

  The claim is read from an unverified payload on purpose. It is a selector, not
  a credential: it decides *which* key to use, never *whether* a key is needed.
  Naming another tenant's application only means the request is checked against
  that tenant's public key, which nothing but that tenant's own Discord
  application can satisfy.

  Keys come from the tenant credential store and are read on every request, so
  storing, rotating, or deleting a key in the portal takes effect immediately.
  Environment keys are not accepted.
  """

  require Logger

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Tenancy

  @provider "discord"
  @key "public_key"
  @signature_bytes 64
  @public_key_bytes 32
  @application_id ~r/^[0-9]{1,32}$/

  @doc """
  The tenant an interaction payload belongs to, or `:error`.

  A claimed `application_id` resolves to the tenant that claimed it. Anything
  else - an application nobody claimed, a payload that names none, an id that is
  not a snowflake - resolves to the default tenant. That is what makes a
  single-application deployment work with nothing stored but a public key, and
  it is the whole of the fallback: there is deliberately no shape of payload
  that resolves to no tenant and skips verification.

  Falling back is safe because the default tenant is not a weaker check, only a
  different key. The only interaction it can ever authenticate is one signed by
  the default tenant's own Discord application, so an unclaimed payload buys an
  attacker exactly the 401 a claimed one would.

  `:error` is reserved for a body that is not an object at all, which no Discord
  interaction is.
  """
  def tenant_for(%{"application_id" => application_id}) when is_binary(application_id) do
    if Regex.match?(@application_id, application_id) do
      {:ok, claimed(application_id) || Tenancy.default_slug()}
    else
      {:ok, Tenancy.default_slug()}
    end
  end

  def tenant_for(params) when is_map(params), do: {:ok, Tenancy.default_slug()}
  def tenant_for(_params), do: :error

  # The id is shape-checked first so junk never becomes a query, and matched
  # exactly: a claim is the whole snowflake or nothing.
  defp claimed(application_id) do
    case Tenant.get_by_discord_application_id(application_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Tenant{slug: slug}} -> slug
      _ -> nil
    end
  end

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
