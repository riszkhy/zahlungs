defmodule ZahlungsWeb.ServiceReceiptControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures

  require Ecto.Query

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
    assert response =~ "Rp 52.500"
    assert response =~ "Rp 60.000"
    assert response =~ "Rp 7.500"
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
    assert response =~ "Rp 245.000"
    assert response =~ "Rp 248.000"
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
    assert response =~ "Rp 735.000"
    assert response =~ "Rp 744.000"
  end

  describe "a bill's receipt" do
    setup %{cashier: cashier} do
      bill = service_product_fixture(%{category: "tagihan", cost: "1500", margin_value: "3000"})

      tx =
        service_fixture(cashier, bill, %{
          "bill_amount" => "245000",
          "customer_ref" => "530011223344",
          "amount_paid" => "250000"
        })

      %{tx: tx}
    end

    defp receipt(conn, user, tx),
      do: conn |> log_in_user(user) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    test "says who is billed, then the money: bill, admin fee, total", %{
      conn: conn,
      cashier: cashier,
      tx: tx
    } do
      response = receipt(conn, cashier, tx)

      assert response =~ "ID pelanggan"
      refute response =~ "Nomor tujuan"

      assert response =~
               ~r/ID pelanggan.*class="line".*Tagihan.*Rp 245\.000.*Biaya admin.*Rp 3\.000.*Total.*Rp 248\.000.*Dibayar.*Rp 250\.000.*Kembalian.*Rp 2\.000/s

      refute response =~ ",00"
    end

    test "shows the bill's reference and the meter's reading, when there are any", %{
      conn: conn,
      cashier: cashier,
      tx: tx
    } do
      response = receipt(conn, cashier, tx)
      refute response =~ "Ref tagihan"
      refute response =~ "Stand meter"

      Zahlungs.Repo.update_all(
        Ecto.Query.where(Zahlungs.Services.Transaction, id: ^tx.id),
        set: [bill_reference: "AAAA1111BBBB", meter_reading: "00001000-00001100"]
      )

      response = receipt(build_conn(), cashier, tx)
      assert response =~ "Ref tagihan"
      assert response =~ "AAAA1111BBBB"
      assert response =~ "Stand meter"
      assert response =~ "00001000-00001100"
    end
  end

  test "a top-up keeps its number's label and has no admin fee", %{conn: conn, cashier: cashier} do
    tx = service_fixture(cashier, service_product_fixture())

    response =
      conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200)

    assert response =~ "Nomor tujuan"
    refute response =~ "ID pelanggan"
    refute response =~ "Biaya admin"
  end

  test "names the cashier, or their email when they have no name", %{conn: conn, cashier: cashier} do
    tx = service_fixture(cashier, service_product_fixture())

    assert conn |> log_in_user(cashier) |> get("/services/#{tx.id}/receipt") |> html_response(200) =~
             "Kasir: #{cashier.email}"

    named = user_on_shift_fixture(%{name: "Bu Sari"})
    tx = service_fixture(named, service_product_fixture())

    response =
      build_conn()
      |> log_in_user(named)
      |> get("/services/#{tx.id}/receipt")
      |> html_response(200)

    assert response =~ "Kasir: Bu Sari"
    refute response =~ named.email
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
