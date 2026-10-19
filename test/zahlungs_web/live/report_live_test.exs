defmodule ZahlungsWeb.ReportLiveTest do
  @moduledoc "Access-control + render tests for the sales report via get/2 (no lazy_html)."
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/reports/sales access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/reports/sales")) == "/users/log_in"
    end

    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/sales")
      assert redirected_to(conn) == "/"
    end

    test "renders the report for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/reports/sales")
      response = html_response(conn, 200)
      assert response =~ "Sales Report"
      assert response =~ "Gross profit"
      assert response =~ "Sales by category"
    end
  end

  describe "/reports/consignment access control" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/consignment")
      assert redirected_to(conn) == "/"
    end

    test "renders the settlement report for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/reports/consignment")
      assert html_response(conn, 200) =~ "Consignment Settlement"
    end

    test "lists each supplier's balance and totals them" do
      import Zahlungs.CatalogFixtures
      import Zahlungs.ShiftsFixtures
      import ZahlungsWeb.LiveDriver

      cashier = user_on_shift_fixture()
      supplier = supplier_fixture()

      product =
        product_fixture(
          consignment: true,
          supplier_id: supplier.id,
          purchase_price: Decimal.new("700"),
          price: Decimal.new("1000"),
          stock: 10
        )

      {:ok, _} =
        Zahlungs.Sales.create_sale(cashier, [%{product_id: product.id, quantity: 2}], %{
          amount_paid: "2000"
        })

      socket = mount_live(ZahlungsWeb.ReportLive.Consignment, admin_fixture())
      row = Enum.find(socket.assigns.settlement, &(&1.supplier_id == supplier.id))

      assert Decimal.equal?(row.payable, Decimal.new("1400"))
      assert Decimal.equal?(row.outstanding, Decimal.new("1400"))

      summed =
        Enum.reduce(socket.assigns.settlement, Decimal.new(0), &Decimal.add(&2, &1.outstanding))

      assert Decimal.equal?(socket.assigns.totals.outstanding, summed)
      assert html(socket) =~ supplier.name

      # A malformed date range empties the report instead of crashing.
      socket = event(socket, "filter", %{"from" => "nope", "to" => "2026-01-01"})
      assert socket.assigns.settlement == []
    end
  end

  describe "/reports/stock access control" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/stock")
      assert redirected_to(conn) == "/"
    end

    test "renders the stock report for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/reports/stock")
      response = html_response(conn, 200)
      assert response =~ "Stock Report"
      assert response =~ "Out of stock"
    end
  end

  describe "/reports/services" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/services")
      assert redirected_to(conn) == "/"
    end

    test "shows this period's services to admins", %{conn: conn} do
      Zahlungs.ServicesFixtures.assign_account(
        Zahlungs.StoresFixtures.default_store(),
        Zahlungs.ServicesFixtures.deposit_account_fixture()
      )

      cashier = Zahlungs.ShiftsFixtures.user_on_shift_fixture()

      tx =
        Zahlungs.ServicesFixtures.service_fixture(
          cashier,
          Zahlungs.ServicesFixtures.service_product_fixture()
        )

      {:ok, _} = Zahlungs.Services.mark_success(tx, cashier, nil)

      response =
        conn |> log_in_user(admin_fixture()) |> get("/reports/services") |> html_response(200)

      assert response =~ "Laporan layanan"
      assert response =~ "Rp 12.000,00"
      assert response =~ "Rp 1.850,00"
    end

    test "the sales report points to it", %{conn: conn} do
      response =
        conn |> log_in_user(admin_fixture()) |> get("/reports/sales") |> html_response(200)

      assert response =~ ~s(href="/reports/services")
    end
  end
end
