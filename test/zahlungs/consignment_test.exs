defmodule Zahlungs.ConsignmentTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Catalog, Sales, Shifts}
  alias Zahlungs.Catalog.Supplier

  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures

  describe "suppliers" do
    test "create/list/update/soft-delete" do
      assert {:ok, %Supplier{} = supplier} =
               Catalog.create_supplier(%{name: "CV Titipan", phone: "0812"})

      assert supplier in Catalog.list_suppliers()
      assert {:ok, supplier} = Catalog.update_supplier(supplier, %{name: "CV Titipan Jaya"})
      assert supplier.name == "CV Titipan Jaya"

      {:ok, _} = Catalog.delete_supplier(supplier)
      refute Enum.any?(Catalog.list_suppliers(), &(&1.id == supplier.id))
    end

    test "requires a name" do
      assert {:error, changeset} = Catalog.create_supplier(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "consignment product" do
    test "requires a supplier when marked as consignment" do
      assert {:error, changeset} =
               Catalog.create_product(%{
                 name: "Titip A",
                 price: "1000",
                 stock: 5,
                 consignment: true
               })

      assert %{supplier_id: [_ | _]} = errors_on(changeset)
    end

    test "can be created with a supplier" do
      supplier = supplier_fixture()

      assert {:ok, product} =
               Catalog.create_product(%{
                 name: "Titip A",
                 price: "1000",
                 stock: 5,
                 consignment: true,
                 supplier_id: supplier.id
               })

      assert product.consignment
      assert product.supplier_id == supplier.id
    end
  end

  describe "settlement" do
    setup do
      user = user_on_shift_fixture()
      supplier = supplier_fixture()

      product =
        product_fixture(
          consignment: true,
          supplier_id: supplier.id,
          purchase_price: Decimal.new("700"),
          price: Decimal.new("1000"),
          stock: 10
        )

      %{user: user, supplier: supplier, product: product}
    end

    test "sums payable (purchase price) and margin for sold consignment items", ctx do
      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{
          amount_paid: "3000"
        })

      today = Zahlungs.LocalTime.today()
      # dev/test share one DB, so scope assertions to this test's supplier.
      row =
        Enum.find(
          Sales.consignment_settlement(today, today),
          &(&1.supplier_id == ctx.supplier.id)
        )

      assert row.supplier == ctx.supplier.name
      assert row.qty_sold == 3
      assert Decimal.equal?(row.revenue, Decimal.new("3000"))
      # payable = 700 * 3
      assert Decimal.equal?(row.payable, Decimal.new("2100"))
      # margin = 3000 - 2100
      assert Decimal.equal?(row.margin, Decimal.new("900"))
    end

    test "excludes returned sales", ctx do
      {:ok, sale} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 2}], %{
          amount_paid: "2000"
        })

      {:ok, _} = Sales.return_sale(sale)

      today = Zahlungs.LocalTime.today()

      refute Enum.any?(
               Sales.consignment_settlement(today, today),
               &(&1.supplier_id == ctx.supplier.id)
             )
    end

    test "consignment status is the one at the time of sale, not the product's current one",
         ctx do
      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{
          amount_paid: "3000"
        })

      # A regular product sold today, turned into a consignment item afterwards.
      later_supplier = supplier_fixture()
      regular = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: regular.id, quantity: 2}], %{
          amount_paid: "2000"
        })

      {:ok, _} = Catalog.update_product(ctx.product, %{consignment: false, supplier_id: nil})

      {:ok, _} =
        Catalog.update_product(regular, %{consignment: true, supplier_id: later_supplier.id})

      today = Zahlungs.LocalTime.today()
      rows = Sales.consignment_settlement(today, today)

      assert %{qty_sold: 3} = Enum.find(rows, &(&1.supplier_id == ctx.supplier.id))
      refute Enum.any?(rows, &(&1.supplier_id == later_supplier.id))
    end

    test "reports on-hand consignment stock per supplier", ctx do
      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{
          amount_paid: "3000"
        })

      row = Enum.find(Catalog.consignment_stock_on_hand(), &(&1.supplier_id == ctx.supplier.id))
      assert row.supplier == ctx.supplier.name
      # 10 - 3 sold = 7 units left; value at 700 = 4900
      assert row.units == 7
      assert Decimal.equal?(row.cost_value, Decimal.new("4900"))
    end
  end

  describe "consignment_statement/2" do
    setup do
      user = user_on_shift_fixture()
      supplier = supplier_fixture()

      product =
        product_fixture(
          consignment: true,
          supplier_id: supplier.id,
          purchase_price: Decimal.new("700"),
          price: Decimal.new("1000"),
          stock: 10
        )

      %{user: user, supplier: supplier, product: product}
    end

    defp statement_row(from, to, supplier),
      do: Enum.find(Sales.consignment_statement(from, to), &(&1.supplier_id == supplier.id))

    defp pay(user, supplier, amount) do
      {:ok, _} =
        Shifts.add_cash_movement(Shifts.current_shift(user), %{
          "category" => "consignment_payment",
          "amount" => amount,
          "supplier_id" => supplier.id
        })
    end

    test "outstanding is the balance to date, so a payment settles sales of an earlier period",
         ctx do
      {:ok, sale} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{
          amount_paid: "3000"
        })

      # The sale (payable 3 x 700 = 2100) happened last month; the payment is made today.
      today = Zahlungs.LocalTime.today()
      this_month = Date.beginning_of_month(today)
      last_month_end = Date.add(this_month, -1)
      {start, _finish} = Zahlungs.LocalTime.day_range(last_month_end, last_month_end)

      Repo.update_all(from(s in Sales.Sale, where: s.id == ^sale.id),
        set: [inserted_at: NaiveDateTime.add(start, 3600)]
      )

      pay(ctx.user, ctx.supplier, "1500")

      # Last month: sold, nothing paid yet, all of it still owed at month end.
      row = statement_row(Date.beginning_of_month(last_month_end), last_month_end, ctx.supplier)
      assert row.qty_sold == 3
      assert Decimal.equal?(row.payable, Decimal.new("2100"))
      assert Decimal.equal?(row.paid, Decimal.new("0"))
      assert Decimal.equal?(row.outstanding, Decimal.new("2100"))

      # This month: nothing sold, 1500 paid, 600 still owed.
      row = statement_row(this_month, today, ctx.supplier)
      assert row.supplier == ctx.supplier.name
      assert row.qty_sold == 0
      assert Decimal.equal?(row.payable, Decimal.new("0"))
      assert Decimal.equal?(row.paid, Decimal.new("1500"))
      assert Decimal.equal?(row.outstanding, Decimal.new("600"))

      pay(ctx.user, ctx.supplier, "600")

      row = statement_row(this_month, today, ctx.supplier)
      assert Decimal.equal?(row.paid, Decimal.new("2100"))
      assert Decimal.equal?(row.outstanding, Decimal.new("0"))

      # Settled and with no activity in the range: no longer listed.
      tomorrow = Date.add(today, 1)
      refute statement_row(tomorrow, tomorrow, ctx.supplier)
    end

    test "a supplier with an unpaid balance is listed even without activity in the range",
         ctx do
      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 1}], %{
          amount_paid: "1000"
        })

      tomorrow = Date.add(Zahlungs.LocalTime.today(), 1)
      row = statement_row(tomorrow, tomorrow, ctx.supplier)

      assert row.qty_sold == 0
      assert Decimal.equal?(row.outstanding, Decimal.new("700"))
    end
  end
end
