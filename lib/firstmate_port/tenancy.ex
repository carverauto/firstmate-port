defmodule FirstmatePort.Tenancy do
  @moduledoc """
  Schema-per-tenant helpers. Ash context tenant is the Postgres schema name.
  """

  @prefix "t_"

  def schema(%{tenant_schema: schema}) when is_binary(schema) and schema != "", do: schema
  def schema(%{tenant_slug: slug}) when is_binary(slug) and slug != "", do: schema_for(slug)
  def schema(%{tenant: %{slug: slug}}) when is_binary(slug), do: schema_for(slug)
  def schema(_), do: schema_for(default_slug())

  def schema_for(slug) when is_binary(slug), do: @prefix <> slug

  def default_slug do
    Application.get_env(:firstmate_port, :default_tenant_slug, "local")
  end

  def opts(actor, extra \\ []) do
    Keyword.merge([actor: actor, tenant: schema(actor)], extra)
  end
end
