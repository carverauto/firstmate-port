defmodule FirstmatePortWeb.DiscordInteractionsController do
  @moduledoc """
  Public Discord HTTP interactions endpoint. Verifies Ed25519, PING -> PONG, and
  publishes command payloads onto `<tenant>.discord.inbound` through the app's
  Gnat client. This Phoenix service is the only JetStream client.

  Discord sends no tenant context, so the hostname it posted to carries it: each
  tenant is given its own `discord-<tenant>` hostname and the request is checked
  against that tenant's stored `discord`/`public_key` and no one else's. See
  `FirstmatePort.Tenancy.DiscordHost` for the mapping and
  `FirstmatePort.Credentials.Discord` for verification. A hostname that names no
  tenant, and a tenant with no stored key, are both plain 401s: the response
  says nothing about which of the two it was, so the endpoint cannot be used to
  enumerate tenants.

  Tenants store their key through the portal UI or API; environment keys are not
  accepted.
  """

  use FirstmatePortWeb, :controller

  require Logger

  alias FirstmatePort.Credentials.Discord
  alias FirstmatePort.Tenancy.DiscordHost

  # Discord interactions are a few KB; the cap is what a forged request can cost
  # us before the signature is even considered.
  @max_body 64 * 1024

  # Discord signs the unix seconds it sent the interaction at. Rejecting stale
  # timestamps bounds how long a captured request stays replayable. Wide enough
  # to absorb ordinary clock skew between Discord and the pod.
  @max_skew_seconds 300

  def create(conn, params) do
    raw = conn.assigns[:raw_body]
    signature = header(conn, "x-signature-ed25519")
    timestamp = header(conn, "x-signature-timestamp")

    cond do
      not is_binary(raw) or byte_size(raw) > @max_body ->
        halt_with(conn, :request_entity_too_large, "payload too large")

      not fresh?(timestamp) ->
        unauthorized(conn)

      true ->
        authorize(conn, params, raw, signature, timestamp)
    end
  end

  defp authorize(conn, params, raw, signature, timestamp) do
    with {:ok, tenant} <- DiscordHost.tenant(conn.host),
         true <- Discord.verify?(tenant, signature, timestamp, raw) do
      dispatch(conn, params, tenant, raw)
    else
      _ -> unauthorized(conn)
    end
  end

  defp dispatch(conn, params, tenant, raw) do
    if ping?(params) do
      json(conn, %{type: 1})
    else
      case publish(tenant, raw) do
        :ok ->
          json(conn, %{type: 5})

        {:error, reason} ->
          Logger.warning("Discord interaction for #{tenant} not queued: #{inspect(reason)}")

          halt_with(conn, :bad_gateway, "upstream unavailable")
      end
    end
  end

  defp ping?(%{"type" => type}), do: type == 1 or type == "1"
  defp ping?(_), do: false

  defp publish(tenant, body) when is_binary(body) and body != "" do
    subject =
      tenant
      |> FirstmatePort.Tenancy.inbound_subjects()
      |> hd()

    FirstmatePort.NATS.Connection.publish(subject, body)
  end

  defp publish(_tenant, _body), do: :ok

  # A timestamp Discord did not plausibly just send is refused before any key is
  # read. Absent or unparseable is refused too: the signature covers it, so a
  # request without one could never verify anyway.
  defp fresh?(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} -> abs(System.system_time(:second) - seconds) <= max_skew()
      _ -> false
    end
  end

  defp fresh?(_timestamp), do: false

  defp max_skew do
    Application.get_env(:firstmate_port, :discord_max_skew_seconds, @max_skew_seconds)
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp unauthorized(conn), do: halt_with(conn, :unauthorized, "unauthorized")

  defp halt_with(conn, status, body) do
    conn |> put_status(status) |> text(body) |> halt()
  end
end
