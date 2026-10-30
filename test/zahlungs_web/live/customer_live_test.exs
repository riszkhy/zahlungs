defmodule ZahlungsWeb.CustomerLiveTest do
  @moduledoc """
  The admin's customer pages (list, limit, ledger) and the receivables report.
  Access through `get/2`, behaviour through `ZahlungsWeb.LiveDriver`.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.CustomersFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Customers, LocalTime, Sales}
  alias ZahlungsWeb.CustomerLive
  alias ZahlungsWeb.ReportLive

  defp admin do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp credit!(user, customer, total) do
    product = product_fixture(price: Decimal.new(total), stock: 10)

    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        payment_method: "credit",
        customer_id: customer.id,
        due_date: Date.add(LocalTime.today(default_store()), 30)
      })

    sale
  end

  describe "access" do
    test "cashiers are sent away from the customer pages and the report", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert redirected_to(get(conn, "/admin/customers")) == "/"
      assert redirected_to(get(conn, "/reports/receivables")) == "/"
    end

    test "admins see them", %{conn: conn} do
      conn = log_in_user(conn, admin())
      assert html_response(get(conn, "/admin/customers"), 200) =~ "Pelanggan"
      assert html_response(get(conn, "/reports/receivables"), 200) =~ "Laporan piutang"
    end
  end

  describe "customer list" do
    test "shows each customer with what they owe" do
      customer = customer_fixture()
      credit!(user_on_shift_fixture(), customer, "45000")

      html = CustomerLive.Index |> mount_live(admin()) |> html()

      assert html =~ customer.name
      assert html =~ "Rp 45.000,00"
    end

    test "an admin adds a customer and changes a limit" do
      admin = admin()
      name = "Toko Sebelah #{System.unique_integer([:positive])}"

      socket =
        CustomerLive.Index
        |> mount_live(admin, action: :new)
        |> event("save", %{"customer" => %{"name" => name, "credit_limit" => "300000"}})

      assert live_redirect(socket) == "/admin/customers"
      assert [customer] = Customers.list_customers(q: name)
      assert Decimal.equal?(customer.credit_limit, Decimal.new("300000"))

      CustomerLive.Index
      |> mount_live(admin, action: :edit, params: %{"id" => to_string(customer.id)})
      |> event("save", %{"customer" => %{"name" => name, "credit_limit" => "50000"}})

      assert Decimal.equal?(
               Customers.get_customer!(customer.id).credit_limit,
               Decimal.new("50000")
             )
    end

    test "an invalid customer stays on the form with its error" do
      socket =
        CustomerLive.Index
        |> mount_live(admin(), action: :new)
        |> event("save", %{"customer" => %{"name" => "", "credit_limit" => "1"}})

      assert is_nil(live_redirect(socket))
      assert html(socket) =~ "can&#39;t be blank"
    end
  end

  describe "customer ledger" do
    setup do
      cashier = user_on_shift_fixture()
      customer = customer_fixture()
      sale = credit!(cashier, customer, "50000")

      {:ok, payment} =
        Customers.receive_payment(cashier, customer.id, %{
          "amount" => "20000",
          "payment_method" => "cash"
        })

      %{cashier: cashier, customer: customer, sale: sale, payment: payment}
    end

    defp show(user, customer),
      do: mount_live(CustomerLive.Show, user, params: %{"id" => to_string(customer.id)})

    test "lists notes and repayments with the running balance", ctx do
      html = admin() |> show(ctx.customer) |> html()

      assert html =~ ctx.sale.code
      assert html =~ "Rp 20.000,00"
      assert html =~ "Rp 30.000,00"
    end

    test "an admin cancels a repayment", ctx do
      socket =
        admin()
        |> show(ctx.customer)
        |> event("cancel_payment", %{"payment_id" => ctx.payment.id, "reason" => "salah input"})

      assert flash(socket, :info) =~ "dibatalkan"
      assert Decimal.equal?(Customers.balance(ctx.customer), Decimal.new("50000"))
      assert html(socket) =~ "salah input"
    end

    test "an admin hands an overpayment back", ctx do
      admin = admin()
      shift_fixture(admin)
      {:ok, _} = Sales.return_sale(ctx.sale, admin)

      socket =
        admin
        |> show(ctx.customer)
        |> event("refund_overpayment", %{"amount" => "20000"})

      assert flash(socket, :info) =~ "dikembalikan"
      assert Decimal.equal?(Customers.balance(ctx.customer), Decimal.new("0"))
    end
  end

  describe "receivables report" do
    test "lists customers who owe" do
      customer = customer_fixture()
      credit!(user_on_shift_fixture(), customer, "45000")

      html = ReportLive.Receivables |> mount_live(admin()) |> html()

      assert html =~ customer.name
      assert html =~ "Rp 45.000,00"
    end

    test "the overdue filter" do
      socket =
        ReportLive.Receivables
        |> mount_live(admin())
        |> event("filter", %{"overdue" => "true", "from" => "2026-10-01", "to" => "2026-10-31"})

      assert socket.assigns.overdue_only
    end
  end
end
