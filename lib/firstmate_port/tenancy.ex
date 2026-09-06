defmodule FirstmatePort.Tenancy do
  @moduledoc """
  Attribute-based tenancy. Postgres is shared; NATS is one account.
  Streams are named `<tenant>_steer` and `<tenant>_inbound`.
  The Phoenix API is the tenant wall and the only JetStream client.
  """

  @slug ~r/^[a-z][a-z0-9-]{0,62}$/

  def valid_slug?(s) when is_binary(s), do: Regex.match?(@slug, s)
  def valid_slug?(_), do: false

  def slug(%{tenant_slug: s}) when is_binary(s), do: require_slug!(s)
  def slug(%{tenant: %{slug: s}}) when is_binary(s), do: require_slug!(s)
  def slug(s) when is_binary(s), do: require_slug!(s)
  def slug(_), do: default_slug()

  def default_slug do
    Application.get_env(:firstmate_port, :default_tenant_slug, "local")
  end

  def opts(actor, extra \\ []) do
    Keyword.merge([actor: actor, tenant: slug(actor)], extra)
  end

  def steer_stream(tenant), do: "#{slug(tenant)}_steer"
  def inbound_stream(tenant), do: "#{slug(tenant)}_inbound"
  def steer_subjects(tenant), do: ["#{slug(tenant)}.steer.>"]
  def inbound_subjects(tenant), do: ["#{slug(tenant)}.discord.inbound"]

  defp require_slug!(s) do
    if valid_slug?(s) do
      s
    else
      raise ArgumentError, "invalid tenant slug"
    end
  end
end
