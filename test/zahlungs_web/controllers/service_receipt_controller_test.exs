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
    bill = service_product_fixture(%{category: "tagihan", cost: "1500", margin_value: "3000"})

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

  test "a token through the provider shows its owner, power and the token in groups of four",
       %{conn: conn, cashier: cashier} do
    api_store_fixture()

    token =
      service_product_fixture(%{
        category: "token_pln",
        provider_code: "PLN20",
        cost: "20775",
        margin_value: "1225"
      })

    {:ok, owner} = Services.inquire(cashier, token.id, "14123344441")

    {:ok, tx} =
      Services.record(cashier, token.id, %{"inquiry_id" => owner.id, "amount_paid" => "22000"})

    tx = Services.get_transaction!(scope(cashier), tx.id)
    assert tx.token_sn =~ ~r/^\d{20}$/

    response =
      conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    assert response =~ ZahlungsWeb.ServiceLive.Index.group_digits(tx.token_sn)
    assert response =~ "PELANGGAN 4441"
    assert response =~ "R1/900VA"
  end

  test "a bill paid through the provider shows the customer, period and reference",
       %{conn: conn, cashier: cashier} do
    api_store_fixture()
    bill = api_product_fixture()
    {:ok, inquiry} = Services.inquire(cashier, bill.id, "530011223331")

    {:ok, tx} =
      Services.record(cashier, bill.id, %{"inquiry_id" => inquiry.id, "amount_paid" => "750000"})

    tx = Services.get_transaction!(scope(cashier), tx.id)
    assert tx.status == "success"

    response =
      conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    assert response =~ "PELANGGAN 3331"
    assert response =~ "AGU–OKT 2026"
    assert response =~ "3 bulan"
    refute response =~ "lembar"
    assert response =~ "Ref penyedia"
    assert response =~ tx.provider_ref
    assert tx.provider_ref =~ "FAKE-"
    assert response =~ "Rp 735.000,00"
    assert response =~ "Rp 744.000,00"
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
