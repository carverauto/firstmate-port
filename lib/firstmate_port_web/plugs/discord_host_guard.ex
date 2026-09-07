defmodule FirstmatePortWeb.Plugs.DiscordHostGuard do
  @moduledoc """
  Confines the public interactions hostname to `POST /interactions`.

  The gateway already publishes only that path on that hostname. This is the
  second lock: if an HTTPRoute is ever widened, or the app is reached by some
  other route, the portal UI, `/mcp`, `/api`, and the auth endpoints still must
  not answer on a hostname that exists solely for Discord. Anything else there
  gets a bare 404 - the same answer an unrouted host gets, so the hostname
  reveals nothing about what else this deployment runs.

  Inert until `:discord_interactions_host` is configured, because without it no
  hostname is published for Discord and the single-origin localhost default
  serves everything from one host. See `FirstmatePortWeb.DiscordHosts`.

  What it turns away is recorded on `FirstmatePort.Discord.Attempts`. This
  hostname exists for one path, so a request arriving at another one is nearly
  always an endpoint URL with a trailing slash or a typo in it - and Discord
  reports that with the same "could not be verified" as a request that never
  arrived at all. The attempt is filed against the default tenant because
  nothing here has parsed a payload to select one; the path is what the
  operator needs, not the tenant.
  """

  @behaviour Plug

  import Plug.Conn

  alias FirstmatePort.Discord.Attempts
  alias FirstmatePort.Tenancy
  alias FirstmatePortWeb.DiscordHosts

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/interactions", method: "POST"} = conn, _opts), do: conn

  @impl Plug
  def call(conn, _opts) do
    if DiscordHosts.interactions_host?(conn.host) do
      Attempts.record(Tenancy.default_slug(), :wrong_path, %{
        path: "#{conn.method} #{conn.request_path}"
      })

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:not_found, "not found")
      |> halt()
    else
      conn
    end
  end
end
