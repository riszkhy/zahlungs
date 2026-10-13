defmodule Zahlungs.MultiStoreTest do
  @moduledoc """
  Two stores side by side: stock, sales and shifts of one must never be read or
  changed through the other.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Catalog, Sales, Scope, Shifts}

  # Store A is the test's default store; store B is a second branch. One product
  # with 10 units in A and 4 in B, and a cashier on an open shift in each.
  setup do
    store_a = default_store()
    store_b = store_fixture(code: "BBB")
    product = product_fixture(price: Decimal.new("1000"), stock: 10)

    {:ok, _} =
      Catalog.update_product(store_scope(store_b), product_in(product, store_b), %{stock: 4})

    cashier_a = user_on_shift_fixture()
    cashier_b = user_fixture(store_id: store_b.id)
    shift_fixture(cashier_b)
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

    %{
      store_a: store_a,
      store_b: store_b,
      product: product,
      cashier_a: cashier_a,
      cashier_b: cashier_b,
      admin: admin
    }
  end

  defp product_in(product, store), do: Catalog.get_product!(store_scope(store), product.id)

  defp sell(cashier, product, qty) do
    {:ok, sale} =
      Sales.create_sale(cashier, [%{product_id: product.id, quantity: qty}], %{
        amount_paid: "100000"
      })

    sale
  end

  describe "stock" do
    test "each store has its own, and an admin over all stores sees the sum", ctx do
      assert stock_of(ctx.product, ctx.store_a) == 10
      assert stock_of(ctx.product, ctx.store_b) == 4
      assert Catalog.get_product!(all_stores_scope(ctx.admin), ctx.product.id).stock == 14
    end

    test "a new product has stock only in the store it was created in", ctx do
      assert stock_of(product_fixture(stock: 7), ctx.store_b) == 0
    end

    test "a sale takes stock from the cashier's store only", ctx do
      sell(ctx.cashier_b, ctx.product, 3)

      assert stock_of(ctx.product, ctx.store_b) == 1
      assert stock_of(ctx.product, ctx.store_a) == 10
    end

    test "a store cannot sell what only another store has", ctx do
      cart = [%{product_id: ctx.product.id, quantity: 5}]

      assert {:error, {:insufficient_stock, _}} =
               Sales.create_sale(ctx.cashier_b, cart, %{amount_paid: "100000"})

      assert stock_of(ctx.product, ctx.store_b) == 4
      assert {:ok, _} = Sales.create_sale(ctx.cashier_a, cart, %{amount_paid: "100000"})
    end

    test "a return puts stock back in the store that sold it, not the refunder's", ctx do
      sale = sell(ctx.cashier_b, ctx.product, 3)

      # The admin's own store is A.
      assert {:ok, _} = Sales.return_sale(sale, ctx.admin)

      assert stock_of(ctx.product, ctx.store_b) == 4
      assert stock_of(ctx.product, ctx.store_a) == 10
    end

    test "in-stock filter and low-stock list follow the store", ctx do
      only_a = product_fixture(stock: 2)
      search = [search: only_a.sku, in_stock: true]

      assert [_] = Catalog.list_products(store_scope(ctx.store_a), search)
      assert [] = Catalog.list_products(store_scope(ctx.store_b), search)
      assert Catalog.count_products(store_scope(ctx.store_b), search) == 0

      low_b = Catalog.list_low_stock_products(store_scope(ctx.store_b), 5)
      assert ctx.product.id in Enum.map(low_b, & &1.id)

      low_a = Catalog.list_low_stock_products(store_scope(ctx.store_a), 5)
      refute ctx.product.id in Enum.map(low_a, & &1.id)
    end

    test "stock cannot be set while looking at all stores", ctx do
      scope = all_stores_scope(ctx.admin)
      product = Catalog.get_product!(scope, ctx.product.id)

      assert {:error, changeset} = Catalog.update_product(scope, product, %{stock: 99})
      assert %{stock: [_ | _]} = errors_on(changeset)
      assert stock_of(ctx.product, ctx.store_a) == 10

      # Other fields can still be edited.
      assert {:ok, renamed} = Catalog.update_product(scope, product, %{name: "Renamed"})
      assert renamed.name == "Renamed"
    end
  end

  describe "sales" do
    test "a sale belongs to the store of the shift and carries its code", ctx do
      sale = sell(ctx.cashier_b, ctx.product, 1)

      assert sale.store_id == ctx.store_b.id
      assert sale.shift_id == Shifts.current_shift(ctx.cashier_b).id
      assert String.starts_with?(sale.code, "BBB-INV")
    end

    test "lists, counts and the summary of today only cover the scope's store", ctx do
      sale_a = sell(ctx.cashier_a, ctx.product, 1)
      sale_b = sell(ctx.cashier_b, ctx.product, 2)
      scope_a = scope(ctx.cashier_a)
      scope_b = scope(ctx.cashier_b)

      assert Enum.map(Sales.list_sales(scope_a), & &1.id) == [sale_a.id]
      assert Enum.map(Sales.list_sales(scope_b), & &1.id) == [sale_b.id]
      assert Sales.count_sales(scope_b) == 1

      assert %{count: 1, total: total} = Sales.sales_summary_today(scope_b)
      assert Decimal.equal?(total, Decimal.new("2000"))
    end

    test "the sale of another store cannot be fetched", ctx do
      sale_a = sell(ctx.cashier_a, ctx.product, 1)

      assert Sales.get_sale!(scope(ctx.cashier_a), sale_a.id).id == sale_a.id

      assert_raise Ecto.NoResultsError, fn ->
        Sales.get_sale!(scope(ctx.cashier_b), sale_a.id)
      end
    end

    test "an admin sees the picked store, or every store", ctx do
      sale_a = sell(ctx.cashier_a, ctx.product, 1)
      sale_b = sell(ctx.cashier_b, ctx.product, 1)

      picked = Scope.for_user(ctx.admin, ctx.store_b.id)
      assert Enum.map(Sales.list_sales(picked), & &1.id) == [sale_b.id]

      all = all_stores_scope(ctx.admin)
      assert Sales.get_sale!(all, sale_a.id).store.id == ctx.store_a.id
      ids = Enum.map(Sales.list_sales(all, limit: 1000), & &1.id)
      assert sale_a.id in ids and sale_b.id in ids
    end

    test "reports are per store, and the per-store breakdown names each one", ctx do
      sell(ctx.cashier_a, ctx.product, 1)
      sell(ctx.cashier_b, ctx.product, 3)
      today = Zahlungs.LocalTime.today()

      report_a = Sales.sales_report(scope(ctx.cashier_a), today, today)
      report_b = Sales.sales_report(scope(ctx.cashier_b), today, today)

      assert report_a.transactions == 1
      assert Decimal.equal?(report_a.revenue, Decimal.new("1000"))
      assert Decimal.equal?(Decimal.new(report_b.items_sold), Decimal.new(3))
      assert Decimal.equal?(report_b.revenue, Decimal.new("3000"))

      by_store = Sales.sales_by_store(all_stores_scope(ctx.admin), today, today)
      row_b = Enum.find(by_store, &(&1.store == ctx.store_b.name))
      assert row_b.transactions == 1
      assert Decimal.equal?(row_b.revenue, Decimal.new("3000"))
    end
  end

  describe "shifts" do
    test "a shift is opened in the scope's store; all stores is not a drawer", ctx do
      {:ok, shift} = Shifts.open_shift(Scope.for_user(ctx.admin, ctx.store_b.id), "0")
      assert shift.store_id == ctx.store_b.id

      {:ok, other_admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
      assert {:error, :no_store} = Shifts.open_shift(all_stores_scope(other_admin), "0")
    end

    test "shift lists and lookups only cover the scope's store", ctx do
      shift_a = Shifts.current_shift(ctx.cashier_a)
      shift_b = Shifts.current_shift(ctx.cashier_b)

      assert Enum.map(Shifts.list_shifts(scope(ctx.cashier_a)), & &1.id) == [shift_a.id]
      assert Shifts.get_shift!(scope(ctx.cashier_b), shift_b.id).store.id == ctx.store_b.id

      assert_raise Ecto.NoResultsError, fn ->
        Shifts.get_shift!(scope(ctx.cashier_b), shift_a.id)
      end
    end

    test "consignment payments are counted for the store they were paid from", ctx do
      supplier = supplier_fixture()

      {:ok, _} =
        Shifts.add_cash_movement(Shifts.current_shift(ctx.cashier_b), %{
          "category" => "consignment_payment",
          "amount" => "5000",
          "supplier_id" => supplier.id
        })

      today = Zahlungs.LocalTime.today()
      paid = &Shifts.consignment_payments_by_supplier(&1, today, today)

      assert Decimal.equal?(paid.(scope(ctx.cashier_b))[supplier.id], Decimal.new("5000"))
      refute Map.has_key?(paid.(scope(ctx.cashier_a)), supplier.id)
      assert Decimal.equal?(paid.(all_stores_scope(ctx.admin))[supplier.id], Decimal.new("5000"))
    end
  end
end
