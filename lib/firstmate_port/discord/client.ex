defmodule FirstmatePort.Discord.Client do
  @moduledoc """
  The portal's outbound calls to Discord, authenticated with the asking
  tenant's own stored `discord`/`bot_token`.

  The token is read per call out of the credential store, never cached and never
  put in application environment, so revoking or rotating it in the portal takes
  effect on the next message with no restart - the same contract the inbound
  public key has (`FirstmatePort.Credentials.Discord`).

  This is called from a request the caller is waiting on, so it is bounded: one
  attempt, a short receive timeout, and a `{:error, reason}` the caller can hand
  back as a 502 rather than a request that hangs until something else gives up.
  Discord's own rate limiting is not retried here on purpose - a queue of
  questions the captain never asked for is worse than one that failed loudly.
  """

  require Logger

  alias FirstmatePort.Credentials

  @api "https://discord.com/api/v10"
  @provider "discord"
  @key "bot_token"
  @receive_timeout 5_000

  @doc """
  Posts `body` as a message in `channel_id` for `tenant`.

  Returns `{:ok, message_id}`, or `{:error, reason}` where reason is a short
  atom-or-tuple safe to store and show: it names the HTTP status and Discord's
  own error code, never the token and never the response body wholesale.

  `opts[:req_options]` is merged into `Req.new/1`, which is how tests stub the
  HTTP call - the same seam `FirstmatePort.BuildBuddy` uses.
  """
  @spec post_message(term(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(tenant, channel_id, body, opts \\ []) do
    with {:ok, token} <- bot_token(tenant) do
      request(token, channel_id, body, opts)
    end
  end

  @doc "Whether `tenant` has stored a bot token, without reading it out."
  def configured?(tenant), do: match?({:ok, _}, bot_token(tenant))

  defp bot_token(tenant) do
    case Credentials.fetch_secret(tenant, @provider, @key) do
      {:ok, token} -> {:ok, token}
      {:error, :missing} -> {:error, :no_bot_token}
      {:error, :unreadable} -> {:error, :unreadable_bot_token}
    end
  end

  defp request(token, channel_id, body, opts) do
    req =
      Req.new(
        [
          base_url: @api,
          headers: [
            {"authorization", "Bot #{token}"},
            {"user-agent", "firstmate-port (https://github.com/carverauto/firstmate-port, 1.0)"}
          ],
          receive_timeout: @receive_timeout,
          retry: false
        ]
        |> Keyword.merge(configured_options())
        |> Keyword.merge(opts[:req_options] || [])
      )

    case Req.post(req, url: "/channels/#{channel_id}/messages", json: body) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 and is_binary(id) ->
        {:ok, id}

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, :no_message_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, discord_code(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # The `:discord_req_options` seam is how the test suite points this at a stub
  # instead of discord.com when the caller is an HTTP request that has no
  # business carrying `req_options` of its own. Unset everywhere else.
  defp configured_options do
    Application.get_env(:firstmate_port, :discord_req_options, [])
  end

  # Discord answers a refusal with its own numeric code, which is the part worth
  # keeping: 50001 is "missing access", 10003 "unknown channel", 40001
  # "unauthorized". The message beside it can quote request content, so it does
  # not get stored.
  defp discord_code(%{"code" => code}), do: code
  defp discord_code(_body), do: nil

  @doc """
  A short, storable sentence for a `post_message/4` failure.

  Written for the operator reading the `POST /api/captain/calls` response, so it
  names the thing they can go and change.
  """
  def describe({:error, reason}), do: describe(reason)
  def describe(:no_bot_token), do: "no discord/bot_token stored for this tenant"
  def describe(:unreadable_bot_token), do: "a bot token is stored but the vault would not read it"
  def describe(:no_message_id), do: "Discord accepted the message but named no message id"

  def describe({:http, 401, _code}),
    do: "Discord rejected the bot token (401) - rotate discord/bot_token"

  def describe({:http, 403, code}),
    do: "Discord refused (403, code #{code || "none"}) - is the bot in that channel?"

  def describe({:http, 404, code}),
    do: "Discord has no such channel (404, code #{code || "none"}) - check the channel id"

  def describe({:http, 429, _code}), do: "Discord rate limited this bot (429)"
  def describe({:http, status, code}), do: "Discord answered #{status} (code #{code || "none"})"
  def describe({:transport, reason}), do: "could not reach Discord: #{inspect(reason)}"
  def describe(other), do: "could not post to Discord: #{inspect(other)}"
end
