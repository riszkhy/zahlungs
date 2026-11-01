defmodule ZahlungsWeb.ReceiptControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.CatalogFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures

  alias Zahlungs.Sales

  test "renders a print-friendly receipt for authenticated users", %{conn: conn} do
    user = user_on_shift_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)

    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

    conn = conn |> log_in_user(user) |> get("/sales/#{sale.id}/receipt")
    response = html_response(conn, 200)

    assert response =~ sale.code
    # Headed by the store that made the sale.
    assert response =~ "<h1>#{default_store().name}</h1>"
    assert response =~ "window.print()"
    # Standalone page: no app navigation chrome.
    refute response =~ "Manage Products"
  end

  test "redirects guests to the log in page", %{conn: conn} do
    conn = get(conn, "/sales/1/receipt")
    assert redirected_to(conn) == "/users/log_in"
  end

  test "a promoted line shows its promotion on the receipt", %{conn: conn} do
    user = user_on_shift_fixture()
    product = product_fixture(price: Decimal.new("10000"), stock: 10)
    promotion = Zahlungs.PromotionsFixtures.promotion_fixture(%{product_ids: [product.id]})

    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "9000"})

    response = conn |> log_in_user(user) |> get("/sales/#{sale.id}/receipt") |> html_response(200)

    assert response =~ promotion.name
    assert response =~ "Hemat promo"
  end
end
