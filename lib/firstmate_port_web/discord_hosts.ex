defmodule FirstmatePortWeb.DiscordHosts do
  @moduledoc """
  The hostnames this deployment publishes its Discord interactions URL on.

  A deployment serves one interactions URL for every tenant it hosts - the
  interaction payload, not the hostname, says which tenant an interaction is for
  (see `FirstmatePort.Credentials.Discord`). What the hostname decides is
  exposure: a name listed here is public, reachable by Discord, and must
  therefore serve `POST /interactions` and nothing else.

  Configured, never compiled in: `:discord_interactions_hosts` is the list a
  deployment owns (`DISCORD_INTERACTIONS_HOSTS`). Leave it empty - the localhost
  default - and no hostname is treated as public, which is the right answer when
  the portal and the endpoint share one origin in development.

  Listing a hostname here does not route it. The gateway does that; see
  `deploy/examples/carverauto/discord-httproute.yaml`. This list is what teaches
  the app which of its names are the exposed ones, so
  `FirstmatePortWeb.Plugs.DiscordHostGuard` can keep the portal, `/mcp`, `/api`,
  and the auth endpoints off them.
  """

  @doc "The configured interactions hostnames, normalised and deduplicated."
  def hosts do
    :firstmate_port
    |> Application.get_env(:discord_interactions_hosts, [])
    |> List.wrap()
    |> Enum.flat_map(&split/1)
    |> Enum.uniq()
  end

  @doc """
  Whether `host` is one of this deployment's public interactions hostnames.

  False whenever nothing is configured, which keeps the guard that uses this
  inert on a single-origin deployment.
  """
  def interactions_host?(host) do
    case normalize(host) do
      nil -> false
      normalized -> normalized in hosts()
    end
  end

  @doc """
  The interactions URL to hand an operator, or `nil` when none is published.

  The first configured hostname: a deployment lists more than one only while it
  is moving between names, and the first is the one it means.
  """
  def interactions_url do
    case hosts() do
      [host | _] -> "https://#{host}/interactions"
      [] -> nil
    end
  end

  defp split(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp split(_value), do: []

  # `conn.host` carries no port and no trailing dot; a hand-written config value
  # or a raw `Host` header may carry either.
  defp normalize(host) when is_binary(host) do
    normalized =
      host
      |> String.trim()
      |> String.downcase()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.trim_trailing(".")

    if normalized == "", do: nil, else: normalized
  end

  defp normalize(_host), do: nil
end
