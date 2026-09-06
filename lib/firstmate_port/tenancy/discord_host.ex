defmodule FirstmatePort.Tenancy.DiscordHost do
  @moduledoc """
  Maps the `Host` of an inbound Discord interaction to the tenant that owns it.

  Discord puts no tenant context in the payload, so the hostname it was
  configured with carries it. Every tenant gets its own interactions hostname:

      discord-<oss_label>.<suffix>   ->  the default (OSS) tenant
      discord-<tenant>.<suffix>      ->  that tenant

  Both labels are configured, never compiled in: `:discord_host_suffix` is the
  DNS suffix a deployment owns (`.carverauto.dev`) and `:discord_oss_label` is
  the label that stands for the default tenant (`firstmate`). Defaults run on
  localhost with no suffix, which is single-tenant mode: the host is not
  consulted and every interaction belongs to `Tenancy.default_slug/0`.

  Once a suffix is configured the mapping is exact and total. A host that is not
  `discord-<label><suffix>`, or whose label is not a valid tenant slug, resolves
  to no tenant at all, and the caller answers 401. Resolution never falls back to
  the default tenant and never consults another tenant's credentials, so a
  request aimed at the wrong hostname cannot be verified by, or published to, a
  tenant that did not receive it.
  """

  alias FirstmatePort.Tenancy

  @prefix "discord-"

  @doc """
  The tenant a Discord interaction on `host` belongs to.

  `{:ok, slug}` or `:error`. In single-tenant mode (no `:discord_host_suffix`)
  every host resolves to the default tenant; that is the localhost and
  single-app OSS default. With a suffix configured, only
  `discord-<label><suffix>` resolves, and the OSS label maps to the default
  tenant.
  """
  def tenant(host) do
    case suffix() do
      nil -> {:ok, Tenancy.default_slug()}
      suffix -> label_tenant(label(host, suffix))
    end
  end

  @doc """
  Whether `host` is one of this deployment's Discord interaction hostnames.

  Only true when a suffix is configured and the host matches the pattern, so in
  single-tenant mode nothing is treated as a Discord host and the guard that
  uses this stays inert. Note a well-formed host whose label is not a usable
  tenant slug still answers true: it is addressed to the Discord hostnames and
  must be confined to `/interactions` even though no tenant will verify it.
  """
  def interactions_host?(host) do
    case suffix() do
      nil -> false
      suffix -> label(host, suffix) != :error
    end
  end

  @doc "The hostname that serves `tenant`, or `nil` in single-tenant mode."
  def hostname(tenant) do
    case suffix() do
      nil ->
        nil

      suffix ->
        slug = Tenancy.slug(tenant)
        label = if slug == Tenancy.default_slug(), do: oss_label(), else: slug
        @prefix <> label <> suffix
    end
  end

  defp label_tenant(:error), do: :error

  defp label_tenant(label) do
    cond do
      label == oss_label() -> {:ok, Tenancy.default_slug()}
      Tenancy.valid_slug?(label) -> {:ok, label}
      true -> :error
    end
  end

  # The label between `discord-` and the deployment's suffix, or `:error` when
  # the host is not one of ours. The port is stripped because `conn.host` omits
  # it but a raw `Host` header does not.
  defp label(host, suffix) when is_binary(host) do
    normalized =
      host
      |> String.downcase()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.trim_trailing(".")

    with true <- String.starts_with?(normalized, @prefix),
         true <- String.ends_with?(normalized, suffix),
         label <-
           binary_part(
             normalized,
             byte_size(@prefix),
             byte_size(normalized) - byte_size(@prefix) - byte_size(suffix)
           ),
         true <- label != "" and not String.contains?(label, ".") do
      label
    else
      _ -> :error
    end
  end

  defp label(_host, _suffix), do: :error

  defp suffix do
    case Application.get_env(:firstmate_port, :discord_host_suffix) do
      value when is_binary(value) and value != "" ->
        value |> String.downcase() |> ensure_leading_dot()

      _ ->
        nil
    end
  end

  defp ensure_leading_dot("." <> _ = suffix), do: suffix
  defp ensure_leading_dot(suffix), do: "." <> suffix

  defp oss_label do
    Application.get_env(:firstmate_port, :discord_oss_label, "firstmate")
  end
end
