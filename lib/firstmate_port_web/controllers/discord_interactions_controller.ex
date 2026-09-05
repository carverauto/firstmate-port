defmodule FirstmatePortWeb.DiscordInteractionsController do
  @moduledoc """
  Public Discord HTTP interactions endpoint. Verifies Ed25519, PING -> PONG,
  and publishes command payloads onto `<tenant>.discord.inbound` through the
  app's Gnat client. This Phoenix service is the only JetStream client;
  Discord has no tenant context, so interactions land in the default tenant.
  """

  use FirstmatePortWeb, :controller

  require Logger

  @max_body 64 * 1024

  def healthz(conn, _params), do: text(conn, "ok")

  def create(conn, params) do
    raw = conn.assigns[:raw_body] || ""
    sig = conn |> get_req_header("x-signature-ed25519") |> List.first()
    ts = conn |> get_req_header("x-signature-timestamp") |> List.first()

    cond do
      byte_size(raw) > @max_body ->
        conn |> put_status(:request_entity_too_large) |> text("payload too large")

      not verify(sig, ts, raw) ->
        conn |> put_status(:unauthorized) |> text("unauthorized")

      params["type"] == 1 or params["type"] == "1" ->
        json(conn, %{type: 1})

      true ->
        case publish(raw) do
          :ok ->
            json(conn, %{type: 5})

          {:error, reason} ->
            Logger.warning("Discord interaction not queued: #{inspect(reason)}")
            conn |> put_status(:bad_gateway) |> text("upstream unavailable")
        end
    end
  end

  defp verify(sig, ts, body)
       when is_binary(sig) and is_binary(ts) and is_binary(body) do
    with {:ok, sig_bin} <- decode_hex(sig),
         {:ok, pub} <- public_key(),
         true <- byte_size(sig_bin) == 64,
         true <- byte_size(pub) == 32 do
      :crypto.verify(:eddsa, :none, ts <> body, sig_bin, [pub, :ed25519])
    else
      _ -> false
    end
  end

  defp verify(_, _, _), do: false

  defp public_key do
    case Application.get_env(:firstmate_port, :discord_public_key) do
      key when is_binary(key) and key != "" -> decode_hex(key)
      _ -> {:error, :missing}
    end
  end

  defp decode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp publish(body) when is_binary(body) and body != "" do
    subject =
      FirstmatePort.Tenancy.default_slug()
      |> FirstmatePort.Tenancy.inbound_subjects()
      |> hd()

    FirstmatePort.NATS.Connection.publish(subject, body)
  end

  defp publish(_), do: :ok
end
