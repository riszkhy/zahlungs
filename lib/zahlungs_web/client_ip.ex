defmodule ZahlungsWeb.ClientIp do
  @moduledoc """
  The address a request came from. Behind a reverse proxy the peer is the
  proxy, so `X-Forwarded-For` is read — but only when the peer is one of
  `config :zahlungs, :trusted_proxies` (anyone can send that header). Then the
  rightmost address no trusted proxy added is the client: a forged first hop
  stays to its left.
  """

  @doc "The client's address as text, e.g. `\"183.91.82.154\"`."
  def of(%Plug.Conn{} = conn, trusted \\ Application.get_env(:zahlungs, :trusted_proxies, [])) do
    peer = conn.remote_ip |> :inet.ntoa() |> to_string()

    if peer in trusted do
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find(peer, &(&1 != "" and &1 not in trusted))
    else
      peer
    end
  end
end
