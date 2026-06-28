defmodule ZahlungsWeb.ReceiptControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  alias Zahlungs.Sales

  test "renders a print-friendly receipt for authenticated users", %{conn: conn} do
    user = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)

    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

    conn = conn |> log_in_user(user) |> get("/sales/#{sale.id}/receipt")
    response = html_response(conn, 200)

    assert response =~ sale.code
    assert response =~ "Zahlungs POS"
    assert response =~ "window.print()"
    # Standalone page: no app navigation chrome.
    refute response =~ "Manage Products"
  end

  test "redirects guests to the log in page", %{conn: conn} do
    conn = get(conn, "/sales/1/receipt")
    assert redirected_to(conn) == "/users/log_in"
  end
end
