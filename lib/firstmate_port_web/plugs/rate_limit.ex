defmodule FirstmatePortWeb.Plugs.RateLimit do
  @moduledoc """
  Gates a pipeline or route through `FirstmatePort.Security.RateLimiter`.

  Every response carries `x-ratelimit-limit`, `x-ratelimit-remaining` and
  `x-ratelimit-reset`. A denied request also carries `retry-after` and is
  answered as either:

    * `429` with `{"error": "...", "retry_after": N}` for programmatic
      clients, or
    * `303` back to the sign-in page with a flash for browsers.

  ## Options

    * `:bucket` — required bucket atom from
      `FirstmatePort.Security.RateLimiter`.
    * `:subject` — `:ip` (default) or `:ip_and_actor`, which keys on
      `{ip, current_user.id}` so one signed-in actor cannot spend another's
      budget from behind a shared address.
    * `:response_mode` — `:auto` (default, sniffs `accept`), `:json`, or
      `:html`. Pin JSON-only pipelines to `:json` so a browser-shaped
      `Accept` header cannot turn an API 429 into a redirect.
    * `:json_error` — the `error` value in the 429 body. Defaults to
      `"rate_limited"`; the RFC 8628 token endpoint passes `"slow_down"`
      so `fm-steer` backs off instead of failing.
    * `:html_redirect_to` — path for the 303. Defaults to `"/login"`.
    * `:limit` / `:window_seconds` — override the bucket config. Normally
      unset.

  Place it after `:fetch_session` and `:fetch_live_flash` in HTML pipelines
  so the flash survives the redirect, and after the plug that assigns
  `:current_user` when using `:ip_and_actor`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias FirstmatePort.Security.ClientIP
  alias FirstmatePort.Security.RateLimiter

  @impl true
  def init(opts) do
    response_mode = Keyword.get(opts, :response_mode, :auto)

    if response_mode not in [:auto, :json, :html] do
      raise ArgumentError,
            "RateLimit :response_mode must be :auto, :json or :html (got #{inspect(response_mode)})"
    end

    subject = Keyword.get(opts, :subject, :ip)

    if subject not in [:ip, :ip_and_actor] do
      raise ArgumentError,
            "RateLimit :subject must be :ip or :ip_and_actor (got #{inspect(subject)})"
    end

    %{
      bucket: Keyword.fetch!(opts, :bucket),
      subject: subject,
      response_mode: response_mode,
      json_error: Keyword.get(opts, :json_error, "rate_limited"),
      html_redirect_to: Keyword.get(opts, :html_redirect_to, "/login"),
      limiter_opts: Keyword.take(opts, [:limit, :window_seconds])
    }
  end

  @impl true
  def call(conn, config) do
    subject = subject_key(conn, config.subject)
    {limit, window} = RateLimiter.resolve_bucket(config.bucket, config.limiter_opts)

    case RateLimiter.check_and_record(config.bucket, subject, config.limiter_opts) do
      :ok ->
        remaining = RateLimiter.remaining(config.bucket, subject, config.limiter_opts)
        put_rate_limit_headers(conn, limit, remaining, window)

      {:error, retry_after} ->
        report_denied(conn, config.bucket, retry_after)

        conn
        |> put_rate_limit_headers(limit, 0, window)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> deny(retry_after, config)
        |> halt()
    end
  end

  defp deny(conn, retry_after, config) do
    case response_mode(conn, config.response_mode) do
      :json ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: config.json_error, retry_after: retry_after}))

      :html ->
        conn
        |> maybe_put_flash(
          "Too many attempts. Try again in #{retry_after} #{pluralize(retry_after)}."
        )
        |> put_resp_header("location", config.html_redirect_to)
        |> send_resp(303, "")
    end
  end

  defp response_mode(_conn, :json), do: :json
  defp response_mode(_conn, :html), do: :html

  defp response_mode(conn, :auto) do
    case get_req_header(conn, "accept") do
      [accept | _] -> if String.contains?(accept, "text/html"), do: :html, else: :json
      [] -> :json
    end
  end

  # Flash lives in conn.assigns from Phoenix 1.8 on, and only exists on
  # pipelines that ran fetch_live_flash. Skip it rather than crash a JSON-shaped
  # conn that resolved to :html.
  defp maybe_put_flash(conn, message) do
    if Map.has_key?(conn.assigns, :flash) do
      Phoenix.Controller.put_flash(conn, :error, message)
    else
      conn
    end
  end

  defp subject_key(conn, :ip), do: ClientIP.resolve(conn)

  defp subject_key(conn, :ip_and_actor) do
    actor =
      case conn.assigns[:current_user] do
        %{id: id} -> id
        _ -> :anonymous
      end

    {ClientIP.resolve(conn), actor}
  end

  defp put_rate_limit_headers(conn, limit, remaining, window) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(remaining, 0)))
    |> put_resp_header(
      "x-ratelimit-reset",
      Integer.to_string(System.system_time(:second) + window)
    )
  end

  defp report_denied(conn, bucket, retry_after) do
    Logger.warning(
      "security: rate limit #{bucket} denied #{conn.method} #{conn.request_path} " <>
        "for #{retry_after}s"
    )

    :telemetry.execute(
      [:firstmate_port, :security, :rate_limit, :denied],
      %{retry_after: retry_after},
      %{bucket: bucket, route: conn.request_path, method: conn.method}
    )
  end

  defp pluralize(1), do: "second"
  defp pluralize(_seconds), do: "seconds"
end
