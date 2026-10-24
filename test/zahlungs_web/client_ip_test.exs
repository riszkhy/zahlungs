defmodule ZahlungsWeb.ClientIpTest do
  @moduledoc "Who sent a request: the peer, or what a trusted proxy says it forwarded."
  use ExUnit.Case, async: true

  alias ZahlungsWeb.ClientIp

  defp conn(ip, forwarded \\ nil) do
    conn = %{Plug.Test.conn(:post, "/") | remote_ip: ip}
    if forwarded, do: Plug.Conn.put_req_header(conn, "x-forwarded-for", forwarded), else: conn
  end

  test "the peer, without a trusted proxy" do
    assert ClientIp.of(conn({183, 91, 82, 154}), []) == "183.91.82.154"
    assert ClientIp.of(conn({10, 0, 0, 5}, "183.91.82.154"), []) == "10.0.0.5"
  end

  test "behind a trusted proxy, the rightmost address it didn't add itself" do
    assert ClientIp.of(conn({127, 0, 0, 1}, "183.91.82.154"), ["127.0.0.1"]) == "183.91.82.154"

    # A forged first hop doesn't help: the proxy appended the real one.
    assert ClientIp.of(conn({127, 0, 0, 1}, "183.91.82.154, 1.2.3.4"), ["127.0.0.1"]) ==
             "1.2.3.4"

    assert ClientIp.of(conn({127, 0, 0, 1}, "1.2.3.4, 10.0.0.2"), ["127.0.0.1", "10.0.0.2"]) ==
             "1.2.3.4"
  end

  test "an IPv4 peer on a dual-stack listener is its IPv4 address" do
    mapped = {0, 0, 0, 0, 0, 0xFFFF, 0xB75B, 0x529A}
    assert ClientIp.of(conn(mapped), []) == "183.91.82.154"

    proxy = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
    assert ClientIp.of(conn(proxy, "183.91.82.154"), ["127.0.0.1"]) == "183.91.82.154"
  end

  test "a trusted proxy that forwarded nothing is the peer" do
    assert ClientIp.of(conn({127, 0, 0, 1}), ["127.0.0.1"]) == "127.0.0.1"
  end
end
