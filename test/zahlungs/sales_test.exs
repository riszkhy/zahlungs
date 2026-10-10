defmodule Zahlungs.SalesTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.Sales

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures

  describe "create_sale/3" do
    test "records a sale with items (incl. purchase price snapshot) and decrements stock" do
      user = user_on_shift_fixture()

      product =
        product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("700"), stock: 10)

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

      assert stock_of(product) == 7
    end

    test "applies discount and tax to the total" do
      user = user_on_shift_fixture()
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

    test "rejects a negative discount, a discount above the subtotal, and a negative tax" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      cart = [%{product_id: product.id, quantity: 2}]

      for {payment, error} <- [
            {%{discount: "-500"}, :invalid_discount},
            {%{discount: "2001"}, :invalid_discount},
            {%{"discount" => "-0.01"}, :invalid_discount},
            {%{tax: "-1"}, :invalid_tax}
          ] do
        payment = Map.put(payment, :amount_paid, "100000")
        assert {:error, ^error} = Sales.create_sale(user, cart, payment)
      end

      assert stock_of(product) == 10
    end

    test "accepts a discount equal to the subtotal (a free sale)" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
                 discount: "2000",
                 amount_paid: "0"
               })

      assert Decimal.equal?(sale.total, Decimal.new("0"))
    end

    test "treats amounts that aren't finite numbers as zero" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
                 discount: "NaN",
                 tax: "Infinity",
                 amount_paid: "1000"
               })

      assert Decimal.equal?(sale.total, Decimal.new("1000"))
    end

    test "records the sale on the cashier's open shift, ignoring a shift_id from the caller" do
      user = user_fixture()
      other_shift = shift_fixture(user_fixture())
      product = product_fixture(price: Decimal.new("1000"), stock: 5)
      shift = shift_fixture(user)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
                 amount_paid: "1000",
                 shift_id: other_shift.id
               })

      assert sale.shift_id == shift.id
    end

    test "refuses a sale when the cashier has no open shift (stock unchanged)" do
      user = user_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 5)
      cart = [%{product_id: product.id, quantity: 1}]

      assert {:error, :no_open_shift} = Sales.create_sale(user, cart, %{amount_paid: "1000"})

      shift = shift_fixture(user)
      {:ok, _} = Zahlungs.Shifts.close_shift(shift, 0)

      assert {:error, :no_open_shift} = Sales.create_sale(user, cart, %{amount_paid: "1000"})
      assert stock_of(product) == 5
    end

    test "defaults to cash payment method" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 5)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
                 amount_paid: "1000"
               })

      assert sale.payment_method == "cash"
    end

    test "non-cash payment settles the exact total and ignores amount_paid" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("5000"), stock: 5)

      assert {:ok, sale} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
                 payment_method: "qris"
               })

      assert sale.payment_method == "qris"
      assert Decimal.equal?(sale.amount_paid, Decimal.new("5000"))
      assert Decimal.equal?(sale.change_due, Decimal.new(0))
    end

    test "cash payment below total is rejected, but non-cash is not" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("5000"), stock: 5)
      cart = [%{product_id: product.id, quantity: 1}]

      assert {:error, :insufficient_payment} =
               Sales.create_sale(user, cart, %{amount_paid: "1000", payment_method: "cash"})

      assert {:ok, _} = Sales.create_sale(user, cart, %{amount_paid: "0", payment_method: "card"})
    end

    test "aggregates duplicate product lines" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      cart = [%{product_id: product.id, quantity: 1}, %{product_id: product.id, quantity: 2}]
      assert {:ok, sale} = Sales.create_sale(user, cart, %{amount_paid: "3000"})

      assert [item] = sale.items
      assert item.quantity == 3
      assert stock_of(product) == 7
    end

    test "rejects an empty cart" do
      assert {:error, :empty_cart} = Sales.create_sale(user_fixture(), [], %{amount_paid: "0"})
    end

    test "rejects insufficient payment" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      assert {:error, :insufficient_payment} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
                 amount_paid: "1000"
               })
    end

    test "refuses to oversell and rolls back (stock unchanged)" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 2)

      assert {:error, {:insufficient_stock, _name}} =
               Sales.create_sale(user, [%{product_id: product.id, quantity: 5}], %{
                 amount_paid: "999999"
               })

      # Whole transaction rolled back: stock not touched.
      assert stock_of(product) == 2
    end
  end

  describe "return_sale/1" do
    test "restores stock and marks the sale returned" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      assert stock_of(product) == 7

      assert {:ok, returned} = Sales.return_sale(sale)
      assert returned.status == "returned"
      assert returned.returned_at
      assert stock_of(product) == 10
    end

    test "cannot return a sale twice" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      assert {:ok, returned} = Sales.return_sale(sale)
      assert {:error, :already_returned} = Sales.return_sale(returned)
    end

    test "a stale `completed` struct cannot return the sale again (stock restored once)" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      # `sale` still says "completed", as it would in a second tab or a double click.
      assert {:ok, _} = Sales.return_sale(sale)
      assert {:error, :already_returned} = Sales.return_sale(sale)
      assert {:error, :not_voidable} = Sales.void_sale(sale, user, "dobel")
      assert stock_of(product) == 10
    end

    test "returned sales drop out of today's summary" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      before = Sales.sales_summary_today(store_scope())
      {:ok, _} = Sales.return_sale(sale)
      after_return = Sales.sales_summary_today(store_scope())

      assert after_return.count == before.count - 1
    end
  end

  describe "void_sale/3" do
    test "restores stock and marks the sale void with a reason and actor" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      assert stock_of(product) == 7

      assert {:ok, voided} = Sales.void_sale(sale, user, "salah qty")
      assert voided.status == "void"
      assert voided.void_reason == "salah qty"
      assert voided.voided_by_id == user.id
      assert voided.voided_at
      assert stock_of(product) == 10
    end

    test "cannot void a non-completed sale" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      {:ok, voided} = Sales.void_sale(sale, user, "x")
      assert {:error, :not_voidable} = Sales.void_sale(voided, user, "again")
    end

    test "a stale `completed` struct cannot void the sale again (stock restored once)" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      assert {:ok, _} = Sales.void_sale(sale, user, "salah qty")
      assert {:error, :not_voidable} = Sales.void_sale(sale, user, "dobel")
      assert {:error, :already_returned} = Sales.return_sale(sale)
      assert stock_of(product) == 10
    end

    test "voided sales drop out of today's summary" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      before = Sales.sales_summary_today(store_scope())
      {:ok, _} = Sales.void_sale(sale, user, "koreksi")
      assert Sales.sales_summary_today(store_scope()).count == before.count - 1
    end

    test "a cashier cannot void a sale from a closed shift, but an admin can" do
      cashier = user_fixture()
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      {:ok, shift} = Zahlungs.Shifts.open_shift(scope(cashier), 0)

      {:ok, sale} =
        Sales.create_sale(cashier, [%{product_id: product.id, quantity: 1}], %{
          amount_paid: "1000"
        })

      {:ok, _} = Zahlungs.Shifts.close_shift(shift, 1000)

      assert {:error, :shift_closed} = Sales.void_sale(sale, cashier, "telat")
      assert {:ok, voided} = Sales.void_sale(sale, admin, "koreksi admin")
      assert voided.status == "void"
    end
  end

  describe "list_sales/1" do
    test "filters by date" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      today = Zahlungs.LocalTime.today()
      ids_today = Sales.list_sales(store_scope(), date: today) |> Enum.map(& &1.id)
      ids_past = Sales.list_sales(store_scope(), date: ~D[2000-01-01]) |> Enum.map(& &1.id)

      assert sale.id in ids_today
      refute sale.id in ids_past
    end

    test "pages with limit/offset, newest first, and count_sales/1 matches the filter" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      day = ~D[2001-05-05]
      {start, _finish} = Zahlungs.LocalTime.day_range(day, day)

      ids =
        for minute <- 1..3 do
          {:ok, sale} =
            Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
              amount_paid: "1000"
            })

          Repo.update_all(from(s in Sales.Sale, where: s.id == ^sale.id),
            set: [inserted_at: NaiveDateTime.add(start, minute * 60)]
          )

          sale.id
        end

      assert Sales.count_sales(store_scope(), date: day) == 3
      assert Sales.count_sales(store_scope(), date: ~D[2001-05-06]) == 0

      page = fn offset -> Sales.list_sales(store_scope(), date: day, limit: 2, offset: offset) end
      assert Enum.map(page.(0), & &1.id) == ids |> Enum.reverse() |> Enum.take(2)
      assert Enum.map(page.(2), & &1.id) == [hd(ids)]
      assert page.(4) == []
    end

    test "date filter and daily breakdown use the shop-local day, not the UTC day" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      # 00:30 shop-local on the 2nd is still the 1st in UTC (offset +7).
      day = ~D[2001-03-02]
      {start, _finish} = Zahlungs.LocalTime.day_range(day, day)
      early_morning = NaiveDateTime.add(start, 30 * 60)

      Repo.update_all(from(s in Sales.Sale, where: s.id == ^sale.id),
        set: [inserted_at: early_morning]
      )

      assert sale.id in (Sales.list_sales(store_scope(), date: day) |> Enum.map(& &1.id))

      refute sale.id in (Sales.list_sales(store_scope(), date: Date.add(day, -1))
                         |> Enum.map(& &1.id))

      assert [%{date: ^day, transactions: 1}] =
               Sales.sales_by_day(store_scope(), Date.add(day, -1), day)
    end
  end

  describe "sales_report/2 and top_products/3" do
    test "aggregates completed sales with gross profit and lists top products" do
      user = user_on_shift_fixture()

      product =
        product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("600"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      today = Zahlungs.LocalTime.today()
      report = Sales.sales_report(store_scope(), today, today)

      assert report.transactions >= 1
      assert Decimal.gt?(report.gross_sales, Decimal.new("0"))
      assert Decimal.gt?(report.gross_profit, Decimal.new("0"))

      top = Sales.top_products(store_scope(), today, today, 1000)
      assert Enum.any?(top, &(&1.name == product.name and &1.quantity >= 2))
    end

    test "sales_by_category/2 breaks down revenue by category" do
      user = user_on_shift_fixture()
      category = category_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10, category_id: category.id)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

      today = Zahlungs.LocalTime.today()
      rows = Sales.sales_by_category(store_scope(), today, today)
      assert Enum.any?(rows, &(&1.category == category.name and &1.quantity >= 3))
    end

    test "sales_by_day/2 and sales_by_cashier/2 break down the period" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      today = Zahlungs.LocalTime.today()

      day_rows = Sales.sales_by_day(store_scope(), today, today)
      assert Enum.any?(day_rows, &(&1.transactions >= 1))

      cashier_rows = Sales.sales_by_cashier(store_scope(), today, today)
      assert Enum.any?(cashier_rows, &(&1.cashier == user.email and &1.transactions >= 1))
    end

    test "returned sales are excluded from the report" do
      user = user_on_shift_fixture()

      product =
        product_fixture(price: Decimal.new("1000"), purchase_price: Decimal.new("600"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      today = Zahlungs.LocalTime.today()
      before = Sales.sales_report(store_scope(), today, today)
      {:ok, _} = Sales.return_sale(sale)
      after_return = Sales.sales_report(store_scope(), today, today)

      assert after_return.transactions == before.transactions - 1
    end
  end

  describe "sales_summary_today/0" do
    test "counts and sums sales recorded today" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      summary = Sales.sales_summary_today(store_scope())
      assert summary.count >= 1
      assert Decimal.gt?(summary.total, Decimal.new("0"))
    end
  end
end
