defmodule FirstmatePortWeb.Plugs.LockoutCheck do
  @moduledoc """
  Refuses a sign-in attempt while the account it names is locked out.

  Reads the account identifier from a request param (the email a sign-in form
  posts), and asks
  `FirstmatePort.Security.Lockouts.active_lockout/1`. A locked account gets
  `303` back to sign-in with a flash and a `retry-after` header. Anything else — no identifier in the request, no active lockout —
  passes straight through, so this plug never decides who *may* sign in, only
  who must wait.

  ## Options

    * `:actor_id_param` — required param to read the account identifier from,
      e.g. `"email"`.
    * `:html_redirect_to` — path for the 303. Defaults to `"/login"`.

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

    if is_nil(param) do
      raise ArgumentError, "LockoutCheck requires :actor_id_param"
    end

    %{
      param: param,
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
    conn
    |> maybe_put_flash(
      "Too many failed sign-ins for that account. Try again in about " <>
        "#{max(div(retry_after, 60), 1)} minutes."
    )
    |> put_resp_header("location", config.html_redirect_to)
    |> send_resp(303, "")
  end

  defp maybe_put_flash(conn, message) do
    if Map.has_key?(conn.assigns, :flash) do
      Phoenix.Controller.put_flash(conn, :error, message)
    else
      conn
    end
  end

  defp actor_id(conn, %{param: param}) do
    case conn.params do
      %{^param => value} when is_binary(value) -> Lockouts.actor_key(value)
      _ -> nil
    end
  end
end

