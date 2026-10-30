defmodule ZahlungsWeb.CustomerPaymentReceiptControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.CatalogFixtures
  import Zahlungs.CustomersFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Customers, LocalTime, Sales}

  setup do
    user = user_on_shift_fixture()
    customer = customer_fixture()
    product = product_fixture(price: Decimal.new("50000"), stock: 10)

    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        payment_method: "credit",
        customer_id: customer.id,
        due_date: Date.add(LocalTime.today(default_store()), 30)
      })

    {:ok, payment} =
      Customers.receive_payment(user, customer.id, %{
        "amount" => "20000",
        "payment_method" => "cash"
      })

    %{user: user, customer: customer, sale: sale, payment: payment}
  end

  test "prints a repayment for the store's users", ctx do
    conn =
      ctx.conn |> log_in_user(ctx.user) |> get("/customer_payments/#{ctx.payment.id}/receipt")

    response = html_response(conn, 200)

    assert response =~ ctx.customer.name
    assert response =~ "Rp 20.000,00"
    assert response =~ "Rp 30.000,00"
    assert response =~ "window.print()"
  end

  test "another organization's user gets a 404", ctx do
    other = organization_fixture()

    stranger =
      in_org(other, fn ->
        store = store_fixture()
        Zahlungs.AccountsFixtures.user_fixture(%{store_id: store.id, organization_id: other.id})
      end)

    assert_error_sent 404, fn ->
      ctx.conn |> log_in_user(stranger) |> get("/customer_payments/#{ctx.payment.id}/receipt")
    end
  end

  test "a credit sale's receipt shows the customer and what is owed", ctx do
    conn = ctx.conn |> log_in_user(ctx.user) |> get("/sales/#{ctx.sale.id}/receipt")
    response = html_response(conn, 200)

    assert response =~ ctx.customer.name
    assert response =~ "Sisa utang nota ini"
    assert response =~ "Jatuh tempo"
  end
end
