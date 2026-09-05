defmodule FirstmatePortWeb.DiscordInteractionsController do
  @moduledoc """
  Public Discord HTTP interactions endpoint. Verifies Ed25519, PING -> PONG, and
  publishes command payloads onto `<tenant>.discord.inbound` through the app's
  Gnat client. This Phoenix service is the only JetStream client.

  Discord sends no tenant context, so the signature supplies it: the request is
  checked against every tenant's stored `discord`/`public_key` credential, and
  verification must match exactly one tenant before its payload is published.
  Tenants must store their key through the portal UI or API; environment keys
  are not accepted. See `FirstmatePort.Credentials.Discord`.
  """

  use FirstmatePortWeb, :controller

  require Logger

  alias FirstmatePort.Credentials.Discord

  @max_body 64 * 1024

  def create(conn, params) do
    raw = conn.assigns[:raw_body] || ""
    sig = conn |> get_req_header("x-signature-ed25519") |> List.first()
    ts = conn |> get_req_header("x-signature-timestamp") |> List.first()

    if byte_size(raw) > @max_body do
      conn |> put_status(:request_entity_too_large) |> text("payload too large")
    else
      dispatch(conn, params, Discord.verify(sig, ts, raw), raw)
    end
  end

  defp dispatch(conn, _params, :error, _raw) do
    conn |> put_status(:unauthorized) |> text("unauthorized")
  end

  defp dispatch(conn, params, {:ok, tenant}, raw) do
    if ping?(params) do
      json(conn, %{type: 1})
    else
      case publish(tenant, raw) do
        :ok ->
          json(conn, %{type: 5})

        {:error, reason} ->
          Logger.warning("Discord interaction for #{tenant} not queued: #{inspect(reason)}")

          conn |> put_status(:bad_gateway) |> text("upstream unavailable")
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
end
