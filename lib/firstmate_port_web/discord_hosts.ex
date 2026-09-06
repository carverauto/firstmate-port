defmodule FirstmatePortWeb.DiscordHosts do
  @moduledoc """
  The public hostname serving only `POST /interactions` for this deployment.

  Configure `:discord_interactions_host` through `DISCORD_INTERACTIONS_HOST`.
  Unset keeps the portal and endpoint on one origin for localhost development.
  The payload's application id selects the tenant independently of this host.
  """

  def host do
    :firstmate_port
    |> Application.get_env(:discord_interactions_host)
    |> normalize()
  end

  def interactions_host?(value) do
    case normalize(value) do
      nil -> false
      normalized -> normalized == host()
    end
  end

  def interactions_url do
    case host() do
      nil -> nil
      host -> "https://#{host}/interactions"
    end
  end

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
