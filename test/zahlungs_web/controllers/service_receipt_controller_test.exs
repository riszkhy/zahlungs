defmodule ZahlungsWeb.ServiceReceiptControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services

  setup do
    assign_account(default_store(), deposit_account_fixture())
    %{cashier: user_on_shift_fixture()}
  end

  test "prints the service with its token, price and payment", %{conn: conn, cashier: cashier} do
    product =
      service_product_fixture(%{
        name: "Token PLN 50.000 #{System.unique_integer([:positive])}",
        category: "token_pln",
        cost: "50150",
        margin_value: "2350"
      })

    tx =
      service_fixture(cashier, product, %{
        "customer_ref" => "12345678901",
        "amount_paid" => "60000"
      })

    {:ok, tx} = Services.mark_success(tx, cashier, "5821 0344 9917 2268 4410")

    response =
      conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    assert response =~ "<h1>#{default_store().name}</h1>"
    assert response =~ tx.code
    assert response =~ product.name
    assert response =~ "1234 5678 901"
    assert response =~ "5821 0344 9917 2268 4410"
    assert response =~ "Rp 52.500,00"
    assert response =~ "Rp 60.000,00"
    assert response =~ "Rp 7.500,00"
    assert response =~ "Berhasil"

    local = Zahlungs.LocalTime.to_local(tx.inserted_at, default_store())
    assert response =~ Calendar.strftime(local, "%d %b %Y %H:%M")
    assert response =~ "window.print()"
    refute response =~ ~s(id="menu-drawer")
  end

  test "a bill shows its amount", %{conn: conn, cashier: cashier} do
    bill = service_product_fixture(%{category: "tagihan_pln", cost: "1500", margin_value: "3000"})

    tx =
      service_fixture(cashier, bill, %{
        "bill_amount" => "245000",
        "customer_ref" => "530011223344"
      })

    response =
      conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    assert response =~ "Tagihan"
    assert response =~ "Rp 245.000,00"
    assert response =~ "Rp 248.000,00"
    assert response =~ "Diproses"
  end

  test "another store's service is not found", %{conn: conn, cashier: cashier} do
    tx = service_fixture(cashier, service_product_fixture())
    elsewhere = user_fixture(%{store_id: store_fixture().id})

    assert_error_sent 404, fn ->
      conn |> log_in_user(elsewhere) |> get("/services/#{tx.id}/receipt")
    end
  end

  test "redirects guests to the log in page", %{conn: conn} do
    assert conn |> get("/services/1/receipt") |> redirected_to() == "/users/log_in"
  end
end
