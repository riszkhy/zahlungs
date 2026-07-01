defmodule Zahlungs.SalesTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Sales, Catalog}

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  describe "create_sale/3" do
    test "records a sale with items (incl. purchase price snapshot) and decrements stock" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("700"), stock: 10)

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
      assert Decimal.equal?(item.unit_price, Decimal.new("1000"))
      assert Decimal.equal?(item.purchase_price, Decimal.new("700"))

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

    test "tags the sale with the given shift_id" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 5)
      {:ok, shift} = Zahlungs.Shifts.open_shift(user, 0)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
                 amount_paid: "1000",
                 shift_id: shift.id
               })

      assert sale.shift_id == shift.id
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

  describe "return_sale/1" do
    test "restores stock and marks the sale returned" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      assert Catalog.get_product!(product.id).stock == 7

      assert {:ok, returned} = Sales.return_sale(sale)
      assert returned.status == "returned"
      assert returned.returned_at
      assert Catalog.get_product!(product.id).stock == 10
    end

    test "cannot return a sale twice" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      assert {:ok, returned} = Sales.return_sale(sale)
      assert {:error, :already_returned} = Sales.return_sale(returned)
    end

    test "returned sales drop out of today's summary" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      before = Sales.sales_summary_today()
      {:ok, _} = Sales.return_sale(sale)
      after_return = Sales.sales_summary_today()

      assert after_return.count == before.count - 1
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

  describe "sales_report/2 and top_products/3" do
    test "aggregates completed sales with gross profit and lists top products" do
      user = user_fixture()

      product =
        product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("600"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      today = Date.utc_today()
      report = Sales.sales_report(today, today)

      assert report.transactions >= 1
      assert Decimal.gt?(report.gross_sales, Decimal.new("0"))
      assert Decimal.gt?(report.gross_profit, Decimal.new("0"))

      top = Sales.top_products(today, today, 1000)
      assert Enum.any?(top, &(&1.name == product.name and &1.quantity >= 2))
    end

    test "sales_by_category/2 breaks down revenue by category" do
      user = user_fixture()
      category = category_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10, category_id: category.id)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      today = Date.utc_today()
      rows = Sales.sales_by_category(today, today)
      assert Enum.any?(rows, &(&1.category == category.name and &1.quantity >= 3))
    end

    test "sales_by_day/2 and sales_by_cashier/2 break down the period" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      today = Date.utc_today()

      day_rows = Sales.sales_by_day(today, today)
      assert Enum.any?(day_rows, &(&1.transactions >= 1))

      cashier_rows = Sales.sales_by_cashier(today, today)
      assert Enum.any?(cashier_rows, &(&1.cashier == user.email and &1.transactions >= 1))
    end

    test "returned sales are excluded from the report" do
      user = user_fixture()

      product =
        product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("600"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      today = Date.utc_today()
      before = Sales.sales_report(today, today)
      {:ok, _} = Sales.return_sale(sale)
      after_return = Sales.sales_report(today, today)

      assert after_return.transactions == before.transactions - 1
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
