defmodule FirstmatePortWeb.DiscordInteractionsController do
  @moduledoc """
  Public Discord HTTP interactions endpoint. Verifies Ed25519, PING -> PONG,
  answers the interactive captain calls this portal posted, and publishes
  everything else onto `<tenant>.discord.inbound` through the app's Gnat client.
  This Phoenix service is the only JetStream client.

  One URL serves every tenant. The interaction payload names the Discord
  application it is for, and the tenant that claimed that application is the one
  whose stored `discord`/`public_key` the request is checked against - see
  `FirstmatePort.Credentials.Discord` for selection and fallback. A missing or
  unusable selected key and a failed signature are all plain 401s, without
  identifying the selected tenant.

  Tenants store their key through the portal UI or API; environment keys are not
  accepted.

  Controller outcomes are recorded on `FirstmatePort.Discord.Attempts`.
  Response semantics and operator guidance live in `docs/credentials.md`,
  "When Discord will not verify the URL".
  """

  use FirstmatePortWeb, :controller

  require Logger

  alias FirstmatePort.CaptainCalls
  alias FirstmatePort.Credentials.Discord
  alias FirstmatePort.Discord.Ask
  alias FirstmatePort.Discord.Attempts
  alias FirstmatePort.Tenancy

  # Discord interactions are a few KB; the cap is what a forged request can cost
  # us before the signature is even considered.
  @max_body 64 * 1024

  # Discord signs the unix seconds it sent the interaction at. Rejecting stale
  # timestamps bounds how long a captured request stays replayable. Wide enough
  # to absorb ordinary clock skew between Discord and the pod.
  @max_skew_seconds 300

  @ping 1
  @message_component 3
  @modal_submit 5

  def create(conn, params) do
    raw = conn.assigns[:raw_body]
    signature = header(conn, "x-signature-ed25519")
    timestamp = header(conn, "x-signature-timestamp")
    tenant = tenant_for(params)

    cond do
      # Nothing read the body. Every Discord interaction is JSON, so this is a
      # hand-rolled request with the wrong content type, not an oversized one -
      # calling it "payload too large" sent more than one operator hunting a
      # size limit that was never the problem.
      not is_binary(raw) ->
        refuse(conn, tenant, params, :unreadable_body,
          status: :bad_request,
          body: "unreadable body"
        )

      byte_size(raw) > @max_body ->
        refuse(conn, tenant, params, :too_large,
          status: :request_entity_too_large,
          body: "payload too large"
        )

      is_nil(signature) ->
        refuse(conn, tenant, params, :no_signature)

      not fresh?(timestamp) ->
        refuse(conn, tenant, params, :stale_timestamp, meta: [skew_seconds: skew(timestamp)])

      true ->
        authorize(conn, params, tenant, raw, signature, timestamp)
    end
  end

  # The claim selects a key; it never decides whether one is needed. Resolving
  # it up front costs one indexed read and no decryption, and it is what lets a
  # refusal be filed against the tenant whose endpoint is being set up.
  defp tenant_for(params) do
    case Discord.tenant_for(params) do
      {:ok, tenant} -> tenant
      :error -> Tenancy.default_slug()
    end
  end

  defp authorize(conn, params, tenant, raw, signature, timestamp) do
    case Discord.verify(tenant, signature, timestamp, raw) do
      :ok -> dispatch(conn, params, tenant, raw)
      {:error, reason} -> refuse(conn, tenant, params, reason)
    end
  end

  defp dispatch(conn, params, tenant, raw) do
    case params do
      %{"type" => type} when type == @ping or type == "1" ->
        record(tenant, params, :pong)
        json(conn, %{type: 1})

      %{"type" => type} when type == @message_component or type == @modal_submit ->
        answer(conn, params, tenant, raw)

      _ ->
        publish_and_defer(conn, params, tenant, raw)
    end
  end

  # A component or modal carrying one of our own custom ids is a captain
  # answering a question this portal asked, and it is answered here rather than
  # queued: Discord is holding the interaction open for three seconds and the
  # answer is a row in this database, not something a downstream worker knows.
  # Anything else on those types belongs to whoever else uses this application,
  # and still goes to NATS untouched.
  defp answer(conn, params, tenant, raw) do
    case Ask.route(params) do
      {:ok, answer} ->
        result = CaptainCalls.answer(tenant, answer)
        outcome = answer_outcome(result)
        record(tenant, params, outcome)
        Logger.info("Discord interaction for #{tenant}: #{Attempts.describe(outcome)}")
        json(conn, Ask.response(result))

      :not_ours ->
        publish_and_defer(conn, params, tenant, raw)
    end
  end

  defp answer_outcome({:ok, _call}), do: :answered
  defp answer_outcome({:open_modal, _call}), do: :modal_opened
  defp answer_outcome({:error, :unauthorized}), do: :captain_refused
  defp answer_outcome({:error, :not_recorded}), do: :answer_not_recorded
  defp answer_outcome({:error, {:already_answered, _call}}), do: :already_answered
  defp answer_outcome({:error, :not_found}), do: :call_not_found

  defp answer_outcome({:error, reason}) when reason in [:no_choice, :unknown_option],
    do: :invalid_answer

  defp publish_and_defer(conn, params, tenant, raw) do
    case publish(tenant, raw) do
      :ok ->
        record(tenant, params, :published)
        json(conn, %{type: 5})

      {:error, reason} ->
        record(tenant, params, :upstream_unavailable)
        Logger.warning("Discord interaction for #{tenant} not queued: #{inspect(reason)}")

        halt_with(conn, :bad_gateway, "upstream unavailable")
    end
  end

  defp publish(tenant, body) when is_binary(body) and body != "" do
    subject =
      tenant
      |> FirstmatePort.Tenancy.inbound_subjects()
      |> hd()

    FirstmatePort.NATS.Connection.publish(subject, body)
  end

  defp publish(_tenant, _body), do: :ok

  # Authentication failures must not expose the selected tenant or key state.
  # Record the reason for operators; only body errors override the bare 401.
  defp refuse(conn, tenant, params, outcome, opts \\ []) do
    record(tenant, params, outcome, Keyword.get(opts, :meta, []))

    Logger.warning(
      "Discord interaction for #{tenant} refused (#{outcome}): #{Attempts.describe(outcome)}"
    )

    halt_with(
      conn,
      Keyword.get(opts, :status, :unauthorized),
      Keyword.get(opts, :body, "unauthorized")
    )
  end

  defp record(tenant, params, outcome, meta \\ []) do
    meta =
      meta
      |> Map.new()
      |> Map.put(:type, interaction_type(params))
      |> Map.put(:application_id, application_id(params))

    Attempts.record(tenant, outcome, meta)
  end

  defp interaction_type(%{"type" => type}) when is_integer(type), do: type

  defp interaction_type(%{"type" => type}) when is_binary(type) do
    case Integer.parse(type) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp interaction_type(_params), do: nil

  defp application_id(%{"application_id" => id}) when is_binary(id), do: id
  defp application_id(_params), do: nil

  # A timestamp Discord did not plausibly just send is refused before any key is
  # read. Absent or unparseable is refused too: the signature covers it, so a
  # request without one could never verify anyway.
  defp fresh?(timestamp) do
    case skew(timestamp) do
      nil -> false
      seconds -> abs(seconds) <= @max_skew_seconds
    end
  end

  # How far the signed timestamp is from this node's clock, or nil when there is
  # no timestamp to compare. Recorded on a refusal because a pod whose clock has
  # drifted refuses every correctly signed request, and looks identical to a
  # wrong key from outside.
  defp skew(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} -> System.system_time(:second) - seconds
      _ -> nil
    end
  end

  defp skew(_timestamp), do: nil

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp halt_with(conn, status, body) do
    conn |> put_status(status) |> text(body) |> halt()
  end
end
