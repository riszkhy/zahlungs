defmodule Zahlungs.SalesTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Sales, Catalog}

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  describe "create_sale/3" do
    test "records a sale with items and decrements stock" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{
                 amount_paid: "5000"
               })

      assert sale.code =~ "INV"
      assert sale.user_id == user.id
      assert Decimal.equal?(sale.subtotal, Decimal.new("3000"))
      assert Decimal.equal?(sale.total, Decimal.new("3000"))
      assert Decimal.equal?(sale.change_due, Decimal.new("2000"))

      assert [item] = sale.items
      assert item.quantity == 3
      assert Decimal.equal?(item.line_total, Decimal.new("3000"))

      assert Catalog.get_product!(product.id).stock == 7
    end

    test "applies discount and tax to the total" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
                 amount_paid: "2500",
                 discount: "200",
                 tax: "300"
               })

      # 2000 - 200 + 300 = 2100
      assert Decimal.equal?(sale.total, Decimal.new("2100"))
      assert Decimal.equal?(sale.change_due, Decimal.new("400"))
    end

    test "aggregates duplicate product lines" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      cart = [%{product_id: product.id, quantity: 1}, %{product_id: product.id, quantity: 2}]
      assert {:ok, sale} = Sales.create_sale(user, cart, %{amount_paid: "3000"})

      assert [item] = sale.items
      assert item.quantity == 3
      assert Catalog.get_product!(product.id).stock == 7
    end

    test "rejects an empty cart" do
      assert {:error, :empty_cart} = Sales.create_sale(user_fixture(), [], %{amount_paid: "0"})
    end

    test "rejects insufficient payment" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:error, :insufficient_payment} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
                 amount_paid: "1000"
               })
    end

    test "refuses to oversell and rolls back (stock unchanged)" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 2)

      assert {:error, {:insufficient_stock, _name}} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 5}], %{
                 amount_paid: "999999"
               })

      # Whole transaction rolled back: stock not touched.
      assert Catalog.get_product!(product.id).stock == 2
    end
  end

  describe "list_sales/1" do
    test "filters by date" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      today = Date.utc_today()
      ids_today = Sales.list_sales(date: today) |> Enum.map(& &1.id)
      ids_past = Sales.list_sales(date: ~D[2000-01-01]) |> Enum.map(& &1.id)

      assert sale.id in ids_today
      refute sale.id in ids_past
    end
  end

  describe "sales_summary_today/0" do
    test "counts and sums sales recorded today" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      summary = Sales.sales_summary_today()
      assert summary.count >= 1
      assert Decimal.gt?(summary.total, Decimal.new("0"))
    end
  end
end
