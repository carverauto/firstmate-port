defmodule FirstmatePortWeb.Plugs.DiscordHostGuard do
  @moduledoc """
  Confines the public interactions hostnames to `POST /interactions`.

  The gateway already publishes only that path on those hostnames. This is the
  second lock: if an HTTPRoute is ever widened, or the app is reached by some
  other route, the portal UI, `/mcp`, `/api`, and the auth endpoints still must
  not answer on a hostname that exists solely for Discord. Anything else there
  gets a bare 404 - the same answer an unrouted host gets, so the hostname
  reveals nothing about what else this deployment runs.

  Inert until `:discord_interactions_hosts` is configured, because without it no
  hostname is published for Discord and the single-origin localhost default
  serves everything from one host. See `FirstmatePortWeb.DiscordHosts`.
  """

  @behaviour Plug

  import Plug.Conn

  alias FirstmatePortWeb.DiscordHosts

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/interactions", method: "POST"} = conn, _opts), do: conn

  @impl Plug
  def call(conn, _opts) do
    if DiscordHosts.interactions_host?(conn.host) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:not_found, "not found")
      |> halt()
    else
      conn
    end
  end
end
