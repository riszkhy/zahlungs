defmodule Zahlungs.Services.Provider.SbiClientTest do
  @moduledoc """
  `Sbi.Client` against a server on this machine (never SBI): JSON both ways,
  headers sent, timeouts, server errors and pages that aren't JSON.
  """
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Provider.Sbi.Client

  defmodule SbiLike do
    @moduledoc false
    use Plug.Router

    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/V1/api/echo" do
      [sign] = get_req_header(conn, "sign")
      reply(conn, 200, Jason.encode!(%{"data" => Map.put(conn.body_params, "sign", sign)}))
    end

    post "/V1/api/slow" do
      Process.sleep(300)
      reply(conn, 200, "{}")
    end

    post("/V1/api/text", do: reply(conn, 200, "oke"))
    post("/V1/api/boom", do: reply(conn, 500, ~s({"message":"error"})))
    get("/pricelist", do: reply(conn, 200, ~s({"Pulsa":[{"code":"T1"}]})))

    defp reply(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, body)
    end
  end

  setup do
    ref = :"sbi_like_#{System.unique_integer([:positive])}"

    start_supervised!({Plug.Cowboy, scheme: :http, plug: SbiLike, options: [port: 0, ref: ref]})

    base = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    %{base: base, opts: [base_url: base <> "/V1", allow_http: true]}
  end

  test "sends JSON with its headers and reads JSON back", ctx do
    assert {:ok, 200, %{"data" => data}} =
             Client.post(
               "echo",
               %{"mmid" => "MM1"},
               [{"sign", "abc"}, {"content-type", "application/json"}],
               5_000,
               ctx.opts
             )

    assert data == %{"mmid" => "MM1", "sign" => "abc"}
  end

  test "a slow answer is a timeout", ctx do
    assert Client.post("slow", %{}, [], 100, ctx.opts) == {:error, :timeout}
  end

  test "a page that isn't JSON comes back as text", ctx do
    assert Client.post("text", %{}, [], 5_000, ctx.opts) == {:ok, 200, "oke"}
  end

  test "a server error keeps its status", ctx do
    assert {:ok, 500, %{"message" => "error"}} = Client.post("boom", %{}, [], 5_000, ctx.opts)
  end

  test "a closed port is a network error" do
    opts = [base_url: "http://127.0.0.1:1/V1", allow_http: true]
    assert Client.post("echo", %{}, [], 2_000, opts) == {:error, :network}
  end

  test "GETs JSON (the price list)", ctx do
    assert {:ok, 200, %{"Pulsa" => [%{"code" => "T1"}]}} =
             Client.get_json(ctx.base <> "/pricelist", 5_000, allow_http: true)
  end

  test "only HTTPS unless told otherwise", ctx do
    assert_raise ArgumentError, fn ->
      Client.post("echo", %{}, [], 1_000, base_url: ctx.base <> "/V1", allow_http: false)
    end

    assert_raise ArgumentError, fn ->
      Client.get_json(ctx.base <> "/pricelist", 1_000, allow_http: false)
    end
  end
end
