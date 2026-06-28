defmodule ZahlungsWeb.SalesLiveTest do
  @moduledoc """
  Sales history page tested via `get/2` (no lazy_html needed).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  alias Zahlungs.Sales

  describe "/sales" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/sales")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "lists sales for authenticated users", %{conn: conn} do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      {:ok, sale} = Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      conn = conn |> log_in_user(user) |> get("/sales")
      response = html_response(conn, 200)
      assert response =~ "Sales"
      assert response =~ sale.code
    end
  end
end
