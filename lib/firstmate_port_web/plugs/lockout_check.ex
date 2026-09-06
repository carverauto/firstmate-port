defmodule FirstmatePortWeb.Plugs.LockoutCheck do
  @moduledoc """
  Refuses a sign-in attempt while the account it names is locked out.

  Reads the account identifier from a request param (the email a sign-in form
  posts) or from a conn assign, and asks
  `FirstmatePort.Security.Lockouts.active_lockout/1`. A locked account gets
  `423 Locked` with a JSON body, or a `303` back to sign-in with a flash for
  browsers. Anything else — no identifier in the request, no active lockout —
  passes straight through, so this plug never decides who *may* sign in, only
  who must wait.

  ## Options

    * `:actor_id_param` — param to read the account identifier from, e.g.
      `"email"`.
    * `:actor_id_assign` — conn assign to read it from instead, e.g.
      `:current_user` (the `:email` field is used).
    * `:response_mode` — `:auto` (default), `:json` or `:html`.
    * `:html_redirect_to` — path for the 303. Defaults to `"/login"`.

  One of `:actor_id_param` / `:actor_id_assign` is required.

  Place it after `Plug.Parsers` so params are available, and after
  `:fetch_live_flash` on HTML pipelines.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias FirstmatePort.Security.Lockouts

  @impl true
  def init(opts) do
    param = Keyword.get(opts, :actor_id_param)
    assign = Keyword.get(opts, :actor_id_assign)

    if is_nil(param) and is_nil(assign) do
      raise ArgumentError, "LockoutCheck requires :actor_id_param or :actor_id_assign"
    end

    response_mode = Keyword.get(opts, :response_mode, :auto)

    if response_mode not in [:auto, :json, :html] do
      raise ArgumentError,
            "LockoutCheck :response_mode must be :auto, :json or :html (got #{inspect(response_mode)})"
    end

    %{
      param: param,
      assign: assign,
      response_mode: response_mode,
      html_redirect_to: Keyword.get(opts, :html_redirect_to, "/login")
    }
  end

  @impl true
  def call(conn, config) do
    with actor when not is_nil(actor) <- actor_id(conn, config),
         locked_until when not is_nil(locked_until) <- Lockouts.active_lockout(actor) do
      retry_after = max(DateTime.diff(locked_until, DateTime.utc_now(), :second), 1)

      Logger.warning("security: refused #{conn.method} #{conn.request_path} for a locked account")

      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after))
      |> deny(retry_after, config)
      |> halt()
    else
      _ -> conn
    end
  end

  defp deny(conn, retry_after, config) do
    case response_mode(conn, config.response_mode) do
      :json ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          423,
          Jason.encode!(%{error: "account_temporarily_locked", retry_after: retry_after})
        )

      :html ->
        conn
        |> maybe_put_flash(
          "Too many failed sign-ins for that account. Try again in about " <>
            "#{max(div(retry_after, 60), 1)} minutes."
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

  defp maybe_put_flash(conn, message) do
    if Map.has_key?(conn.assigns, :flash) do
      Phoenix.Controller.put_flash(conn, :error, message)
    else
      conn
    end
  end

  defp actor_id(conn, %{param: param, assign: assign}) do
    from_param(conn, param) || from_assign(conn, assign)
  end

  defp from_param(_conn, nil), do: nil

  defp from_param(conn, param) do
    case conn.params do
      %{^param => value} when is_binary(value) -> Lockouts.actor_key(value)
      _ -> nil
    end
  end

  defp from_assign(_conn, nil), do: nil

  defp from_assign(conn, assign) do
    case Map.get(conn.assigns, assign) do
      %{email: email} -> Lockouts.actor_key(email)
      value when is_binary(value) -> Lockouts.actor_key(value)
      _ -> nil
    end
  end
end
