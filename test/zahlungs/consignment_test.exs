defmodule Zahlungs.ConsignmentTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Catalog, Sales}
  alias Zahlungs.Catalog.Supplier

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

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
               Catalog.create_product(%{name: "Titip A", price: "1000", stock: 5, consignment: true})

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
      user = user_fixture()
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

      today = Date.utc_today()
      assert [row] = Sales.consignment_settlement(today, today)

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

      today = Date.utc_today()
      assert Sales.consignment_settlement(today, today) == []
    end

    test "reports on-hand consignment stock per supplier", ctx do
      {:ok, _} =
        Sales.create_sale(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{
          amount_paid: "3000"
        })

      assert [row] = Catalog.consignment_stock_on_hand()
      assert row.supplier == ctx.supplier.name
      # 10 - 3 sold = 7 units left; value at 700 = 4900
      assert row.units == 7
      assert Decimal.equal?(row.cost_value, Decimal.new("4900"))
    end
  end
end
