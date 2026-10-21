defmodule ZahlungsWeb.PpobRefCallbackTest do
  @moduledoc """
  `POST /api/ppob/callback` without a token: Smart Biller Indonesia's callback,
  found by `ref_1` and believed only with the account's password in `rqid`,
  from SBI's address.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Provider.Sbi.StubClient

  @sbi_ip {183, 91, 82, 154}

  defp sbi_account(password) do
    deposit_account_fixture(%{
      mode: "api",
      provider: "sbi",
      credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => password}
    })
  end

  defp pending, do: {:ok, 200, %{"data" => %{"status" => 2, "ref_2" => "S1", "msg" => "PROSES"}}}

  defp sell(cashier, product) do
    StubClient.expect("topup", pending())

    {:ok, tx} =
      Services.record(cashier, product.id, %{
        "customer_ref" => "081234567891",
        "amount_paid" => "12000"
      })

    tx
  end

  setup do
    assign_account(default_store(), sbi_account("pw-sbi"))
    cashier = user_on_shift_fixture()
    pulsa = service_product_fixture(%{provider_code: "T10"})
    %{cashier: cashier, pulsa: pulsa, tx: sell(cashier, pulsa)}
  end

  defp body(ref_1, extra \\ %{}) do
    Map.merge(
      %{
        "ref_1" => ref_1,
        "ref_2" => "S1",
        "status" => 1,
        "total_payment" => "10100",
        "msg" => "TRX T10.081234567891 SUKSES, HRG:10100 SN:R241022.1 REFID:#{ref_1}."
      },
      extra
    )
  end

  defp callback(conn, body, opts \\ []) do
    conn = %{conn | remote_ip: Keyword.get(opts, :ip, @sbi_ip)}

    conn =
      Enum.reduce(Keyword.get(opts, :headers, [{"rqid", "pw-sbi"}]), conn, fn {name, value},
                                                                              conn ->
        put_req_header(conn, name, value)
      end)

    post(conn, "/api/ppob/callback", body)
  end

  defp fresh(tx), do: Zahlungs.Repo.get!(Services.Transaction, tx.id)

  test "settles the service it names, once", %{conn: conn, tx: tx} do
    assert conn |> callback(body(tx.ref_id)) |> json_response(200) == %{"ok" => true}

    tx = fresh(tx)
    assert {tx.status, tx.token_sn} == {"success", "R241022.1"}
    assert Decimal.equal?(tx.cost, Decimal.new("10100"))

    assert build_conn() |> callback(body(tx.ref_id)) |> json_response(200) == %{"ok" => true}
    assert is_nil(fresh(tx).review_reason)
  end

  test "a wrong password or another address is refused", %{conn: conn, tx: tx} do
    assert conn |> callback(body(tx.ref_id), headers: [{"rqid", "salah"}]) |> response(401)
    assert build_conn() |> callback(body(tx.ref_id), headers: []) |> response(401)
    assert build_conn() |> callback(body(tx.ref_id), ip: {1, 2, 3, 4}) |> response(401)

    # X-Forwarded-For counts only from a trusted proxy (none here).
    assert build_conn()
           |> callback(body(tx.ref_id),
             ip: {10, 0, 0, 5},
             headers: [{"rqid", "pw-sbi"}, {"x-forwarded-for", "183.91.82.154"}]
           )
           |> response(401)

    # Nor can a caller pass the address on itself.
    assert build_conn()
           |> callback(body(tx.ref_id),
             ip: {1, 2, 3, 4},
             headers: [{"rqid", "pw-sbi"}, {"x-zahlungs-client-ip", "183.91.82.154"}]
           )
           |> response(401)

    assert fresh(tx).status == "processing"
  end

  test "a ref that isn't an api service is not found", ctx do
    assert ctx.conn |> callback(body("")) |> response(404)
    assert build_conn() |> callback(Map.delete(body("x"), "ref_1")) |> response(404)
    assert build_conn() |> callback(body("ZNOPE")) |> response(404)

    # An inquiry's ref, not (yet) a transaction.
    bill = api_product_fixture(%{provider_code: "PLN"})

    StubClient.expect(
      "inquiry",
      {:ok, 200,
       %{
         "data" => %{
           "status" => 1,
           "ref_2" => "S2",
           "price" => "1000",
           "total_payment" => "3000",
           "msg" => "INQ SUKSES"
         }
       }}
    )

    {:ok, inquiry} = Services.inquire(ctx.cashier, bill.id, "530011223341")
    assert build_conn() |> callback(body(inquiry.ref_id)) |> response(404)

    # A manual service.
    assign_account(default_store(), deposit_account_fixture())

    {:ok, manual} =
      Services.record(ctx.cashier, ctx.pulsa.id, %{
        "customer_ref" => "081234567891",
        "amount_paid" => "12000"
      })

    assert build_conn() |> callback(body(manual.ref_id)) |> response(404)
    assert fresh(manual).status == "processing"
  end

  test "another organization's service needs that account's password", %{conn: conn} do
    other =
      in_org(organization_fixture(), fn ->
        store = store_fixture()
        assign_account(store, sbi_account("pw-lain"))
        cashier = user_on_shift_fixture(%{store_id: store.id})
        sell(cashier, service_product_fixture(%{provider_code: "T10"}))
      end)

    assert conn |> callback(body(other.ref_id)) |> response(401)
    assert fresh(other).status == "processing"

    assert build_conn()
           |> callback(body(other.ref_id), headers: [{"rqid", "pw-lain"}])
           |> json_response(200)

    assert fresh(other).status == "success"
  end
end
