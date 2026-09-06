defmodule FirstmatePort.Credentials do
  @moduledoc """
  Tenant-owned secrets, entered in the portal and encrypted into CNPG.

  Nothing about a tenant's Discord app, GitHub token, or provider API key is
  created with `kubectl`. A tenant fills its own slots through the portal UI or
  `/api/credentials`, the rows land in the shared Postgres with `AshCloak`
  ciphertext in place of the secret, and the cluster only has to hold the vault
  key (see `FirstmatePort.Vault` and `docs/credentials.md`).

  ## Reading a secret back

  `secret/3` is the only path that decrypts, and it exists for the app itself -
  the Discord inbound endpoint reading the selected tenant’s key (see
  `FirstmatePort.Credentials.Discord`). It bypasses authorization on purpose, so
  call it from server-side code with a tenant you already established, never with a
  user-supplied slug. It is also the only caller that sets the context
  `FirstmatePort.Credentials.DecryptGuard` requires, so any other query that
  reaches for the plaintext gets an error rather than a secret. There is no
  cross-tenant read: nothing in the app can decrypt a slot without naming the
  single tenant it belongs to.

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
end
