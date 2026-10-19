defmodule ZahlungsWeb.PpobCallbackControllerTest do
  @moduledoc """
  The provider's callbacks: signed by the account's secret, for a service of
  that account, and only ever moving a processing service to its result.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Provider.Fake

  setup do
    account = api_account_fixture()
    assign_account(default_store(), account)
    cashier = user_on_shift_fixture()
    pulsa = service_product_fixture(%{provider_code: "TSEL10"})

    {:ok, tx} =
      Services.record(cashier, pulsa.id, %{
        "customer_ref" => "081234567899",
        "amount_paid" => "12000"
      })

    %{account: account, tx: tx}
  end

  defp callback(conn, token, params, secret \\ "rahasia-uji") do
    conn
    |> put_req_header("x-fake-signature", Fake.sign(secret, params["ref_id"], params["status"]))
    |> post("/api/ppob/callback/#{token}", params)
  end

  defp status_of(tx), do: Zahlungs.Repo.get!(Services.Transaction, tx.id)

  test "a signed callback settles the pending service, and a repeat changes nothing",
       %{conn: conn, account: account, tx: tx} do
    params = %{
      "ref_id" => tx.ref_id,
      "status" => "success",
      "token_sn" => "SN-CB",
      "provider_ref" => "P1"
    }

    assert conn |> callback(account.callback_token, params) |> json_response(200) == %{
             "ok" => true
           }

    assert {status_of(tx).status, status_of(tx).token_sn} == {"success", "SN-CB"}

    failed = %{"ref_id" => tx.ref_id, "status" => "failed", "message" => "telat"}

    assert build_conn() |> callback(account.callback_token, failed) |> json_response(200) == %{
             "ok" => true
           }

    assert status_of(tx).status == "success"
  end

  test "a wrong signature is refused", %{conn: conn, account: account, tx: tx} do
    params = %{"ref_id" => tx.ref_id, "status" => "success"}

    assert conn |> callback(account.callback_token, params, "bukan") |> response(401)
    assert status_of(tx).status == "processing"
  end

  test "an unknown token, or another account's service, is not found",
       %{conn: conn, account: account, tx: tx} do
    params = %{"ref_id" => tx.ref_id, "status" => "success"}
    assert conn |> callback("tidak-ada", params) |> response(404)

    other = api_account_fixture()
    assert build_conn() |> callback(other.callback_token, params) |> response(404)

    assert build_conn()
           |> callback(account.callback_token, %{"ref_id" => "NOPE", "status" => "success"})
           |> response(404)

    assert status_of(tx).status == "processing"
  end
end
