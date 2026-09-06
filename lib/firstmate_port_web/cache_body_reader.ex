defmodule FirstmatePortWeb.CacheBodyReader do
  @moduledoc """
  Keeps the raw request body for the one endpoint that has to see it byte for
  byte: Discord signs `timestamp <> body`, so the parsed params cannot be
  re-encoded and checked - only the exact bytes that arrived will verify.

  Only `/interactions` is cached, and only up to
  `FirstmatePortWeb.CacheBodyReader.max_body/0`, so a large or slow body cannot
  be parked in memory by anyone who has not signed anything yet. Over the cap,
  the partial read is passed straight through and `Plug.Parsers` turns it into a
  413. Every other request reads as usual and keeps nothing.
  """

  # Discord interactions are a few KB. This is deliberately far below the
  # endpoint's general parser limit.
  @max_body 64 * 1024

  @doc "Largest raw Discord interaction body that will be read and cached."
  def max_body, do: @max_body

  def read_body(%Plug.Conn{request_path: "/interactions"} = conn, opts) do
    opts = Keyword.put(opts, :length, @max_body)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
