defmodule FirstmatePort.Fleet do
  @moduledoc """
  The searchable projection of the fleet log, in the same CNPG database.

  Every record the portal already keeps - GitHub PRs and issues, progress notes,
  farm/demo rolls, no-mistakes runs, uploaded diagrams - is copied into one
  `FirstmatePort.Fleet.Document` row per source record. A document holds the
  record as JSON (`document`), the flattened text that JSON reduces to
  (`search_text`), and, when an operator has turned embeddings on, a vector for
  that text.

  Nothing here is a second store. `FirstmatePort.Fleet.Sync` reads the same
  Postgres rows the portal serves and writes the projection beside them, so a
  fleet log that predates this table is searchable after one sync.

  Search is `FirstmatePort.Fleet.Search`: Postgres full-text search always, plus
  a vector pass when `FirstmatePort.Fleet.Embeddings` is configured. Neither
  stage needs an extension that is not already in the database.
  """

  use Ash.Domain,
    otp_app: :firstmate_port,
    extensions: [AshAi]

  tools do
    tool :search_fleet, FirstmatePort.Fleet.Document, :search_fleet
  end

  resources do
    resource FirstmatePort.Fleet.Document
  end

  @doc """
  The actor the sync and embedding jobs run as, for one tenant.

  Same shape as the actor the GitHub poll builds: a background writer with the
  `:agent` role, which is what `FirstmatePort.Fleet.Document`'s write policies
  require. It is not a `FirstmatePort.Accounts.User` and never signs in.
  """
  def actor(tenant_slug) do
    %{
      role: :agent,
      email: "agent@localhost",
      id: "fleet-sync",
      tenant_slug: FirstmatePort.Tenancy.slug(tenant_slug)
    }
  end

  @doc "Every tenant slug the portal knows, for jobs that run across all of them."
  def tenant_slugs do
    case FirstmatePort.Accounts.Tenant.list(authorize?: false) do
      {:ok, tenants} -> Enum.map(tenants, & &1.slug)
      {:error, _} -> []
    end
  end
end
