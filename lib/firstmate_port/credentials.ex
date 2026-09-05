defmodule FirstmatePort.Credentials do
  @moduledoc """
  Tenant-owned secrets, entered in the portal and encrypted into CNPG.

  Nothing about a tenant's Discord app, GitHub token, or provider API key is
  created with `kubectl`. A tenant fills its own slots through the portal UI or
  `/api/credentials`, the rows land in the shared Postgres with `AshCloak`
  ciphertext in place of the secret, and the cluster only has to hold the vault
  key (see `FirstmatePort.Vault` and `docs/credentials.md`).

  ## Reading a secret back

  `secret/3` and `slot_across_tenants/2` are the only paths that decrypt, and
  they exist for the app itself - the Discord inbound endpoint asking "which
  tenant signed this". They bypass authorization on purpose, so call them from
  server-side code with a tenant you already established, never with a
  user-supplied slug. They are also the only callers that set the context
  `FirstmatePort.Credentials.DecryptGuard` requires, so any other query that
  reaches for the plaintext gets an error rather than a secret.

  There is deliberately no `AshAi` tool block here: an MCP client must not be
  able to enumerate a tenant's secrets.
  """

  use Ash.Domain,
    otp_app: :firstmate_port,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource FirstmatePort.Credentials.Credential
  end

  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Credentials.DecryptGuard

  @doc """
  Creates the slot if the tenant has not filled it, rotates it if they have.

  This is what `PUT /api/credentials/:provider/:key` and the portal form use, so
  a tenant does not have to know whether they are setting a secret for the first
  time. `opts` are the usual `actor:`/`tenant:` pair from
  `FirstmatePort.Tenancy.opts/1`.
  """
  def put(attrs, opts) do
    %{provider: provider, key: key} = attrs

    case Credential.get_slot(provider, key, opts) do
      {:ok, nil} ->
        Credential.create(attrs, opts)

      {:ok, existing} ->
        Credential.rotate(existing, Map.take(attrs, [:value, :description]), opts)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The plaintext in one tenant's slot, or `:error` when the slot is empty.

  Server-side only: it decrypts without authorization, so `tenant` must be a slug
  the caller has already established.
  """
  def secret(tenant, provider, key) do
    Credential
    |> Ash.Query.for_read(:by_slot, %{provider: provider, key: key},
      authorize?: false,
      tenant: FirstmatePort.Tenancy.slug(tenant)
    )
    |> Ash.Query.set_context(DecryptGuard.context())
    |> Ash.Query.load([:value])
    |> Ash.read_one()
    |> case do
      {:ok, %Credential{value: value}} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Every tenant's plaintext for one slot, as `{tenant_slug, value}` pairs.

  Inbound requests from a provider that knows nothing about our tenants - a
  Discord interaction, say - are matched against these to work out who they
  belong to. `limit` bounds the work an unauthenticated request can cause.
  """
  def slot_across_tenants(provider, key, limit \\ 200) do
    Credential
    |> Ash.Query.for_read(:every_tenant_slot, %{provider: provider, key: key},
      authorize?: false,
      tenant: nil
    )
    |> Ash.Query.set_context(DecryptGuard.context())
    |> Ash.Query.load([:value])
    |> Ash.Query.limit(limit)
    |> Ash.read()
    |> case do
      {:ok, rows} ->
        for %Credential{tenant_slug: slug, value: value} <- rows,
            is_binary(value),
            do: {slug, value}

      {:error, _} ->
        []
    end
  end
end
