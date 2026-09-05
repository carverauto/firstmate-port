defmodule FirstmatePortWeb.CacheBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn =
          if conn.request_path == "/interactions" do
            Plug.Conn.assign(conn, :raw_body, body)
          else
            conn
          end

        {:ok, body, conn}

      other ->
        other
    end
  end
end
