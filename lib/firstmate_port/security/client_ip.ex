defmodule FirstmatePort.Security.ClientIP do
  @moduledoc """
  Resolves the client address used for rate limiting and lockout metadata.

  Behind a proxy `conn.remote_ip` is the proxy's address, so every request
  collapses into one bucket and the limiter would lock out the whole internet
  at once. Trusting a forwarded header blindly is the opposite failure: the
  header is attacker-controlled unless a proxy you trust rewrote it.

  So the header is configuration, not a guess. Deployments declare which
  header their edge actually sets, and how many proxy hops sit between the
  app and the client:

      config :firstmate_port, :client_ip,
        header: "x-forwarded-for",
        trusted_hops: 0

  * `header: nil` (the default) uses `conn.remote_ip`. Correct for
    `mix phx.server` and Docker Compose, where nothing is in front.
  * `header: "x-forwarded-for"` reads the list right-to-left.
    `trusted_hops: 0` takes the rightmost entry — the address the closest
    proxy observed, which a client cannot forge. Each additional hop steps
    one entry further left, past a proxy you have decided to trust.
  * Any other header name (`cf-connecting-ip`, `true-client-ip`) is read as
    a single value. Only set one of those when the edge that populates it is
    the only way traffic can reach the app; otherwise a client can send it.

  See `docs/security.md` for the deployment matrix.
  """

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{} = conn) do
    config = Application.get_env(:firstmate_port, :client_ip) || []

    case Keyword.get(config, :header) do
      header when is_binary(header) and header != "" ->
        from_header(conn, String.downcase(header), Keyword.get(config, :trusted_hops, 0))

      _ ->
        remote_ip(conn)
    end
  end

  defp from_header(conn, "x-forwarded-for", trusted_hops) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> hop_from_right(trusted_hops)
    |> case do
      nil -> remote_ip(conn)
      address -> address
    end
  end

  defp from_header(conn, header, _trusted_hops) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] ->
        case String.trim(value) do
          "" -> remote_ip(conn)
          address -> address
        end

      [] ->
        remote_ip(conn)
    end
  end

  # Index from the right so a client prepending its own entries cannot shift
  # the one we read. A too-large `trusted_hops` clamps at the leftmost entry
  # rather than falling off the list.
  defp hop_from_right([], _hops), do: nil

  defp hop_from_right(entries, hops) do
    index = max(length(entries) - 1 - max(hops, 0), 0)
    Enum.at(entries, index)
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: "unknown"

  defp remote_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip |> :inet.ntoa() |> to_string()
  rescue
    ArgumentError -> "unknown"
  end
end
