defmodule FirstmatePort.Security.ClientIPTest do
  use ExUnit.Case, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Security.ClientIP

  defp conn(headers, remote_ip \\ {203, 0, 113, 9}) do
    Enum.reduce(headers, %{Plug.Test.conn(:get, "/") | remote_ip: remote_ip}, fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  defp configure(opts), do: put_env(:client_ip, opts)

  test "falls back to the socket peer when no header is configured" do
    configure(header: nil)
    assert ClientIP.resolve(conn([{"x-forwarded-for", "10.0.0.1"}])) == "203.0.113.9"
  end

  test "reads x-forwarded-for from the right so a client cannot prepend its way in" do
    configure(header: "x-forwarded-for", trusted_hops: 0)
    # The client claimed 1.1.1.1; the closest proxy appended what it really saw.
    assert ClientIP.resolve(conn([{"x-forwarded-for", "1.1.1.1, 198.51.100.7"}])) ==
             "198.51.100.7"
  end

  test "trusted_hops steps left past proxies you have decided to trust" do
    configure(header: "x-forwarded-for", trusted_hops: 1)

    assert ClientIP.resolve(conn([{"x-forwarded-for", "1.1.1.1, 198.51.100.7, 192.0.2.4"}])) ==
             "198.51.100.7"
  end

  test "trusted_hops past the start of the list clamps at the leftmost entry" do
    configure(header: "x-forwarded-for", trusted_hops: 9)
    assert ClientIP.resolve(conn([{"x-forwarded-for", "1.1.1.1, 198.51.100.7"}])) == "1.1.1.1"
  end

  test "a single-value header is taken whole" do
    configure(header: "cf-connecting-ip")
    assert ClientIP.resolve(conn([{"cf-connecting-ip", "198.51.100.7"}])) == "198.51.100.7"
  end

  test "a configured header that is absent or blank falls back to the socket peer" do
    configure(header: "cf-connecting-ip")
    assert ClientIP.resolve(conn([])) == "203.0.113.9"
    assert ClientIP.resolve(conn([{"cf-connecting-ip", "  "}])) == "203.0.113.9"

    configure(header: "x-forwarded-for", trusted_hops: 0)
    assert ClientIP.resolve(conn([{"x-forwarded-for", " , "}])) == "203.0.113.9"
  end
end
