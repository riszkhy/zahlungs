defmodule Zahlungs.CatalogTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.Catalog
  alias Zahlungs.Catalog.{Category, Product}

  import Zahlungs.CatalogFixtures

  describe "categories" do
    test "create_category/1 with valid data creates a category" do
      # Use a unique name: dev and test share one database, so a hardcoded name
      # could collide with seeded data (e.g. "Drinks").
      name = "Category #{System.unique_integer([:positive])}"
      assert {:ok, %Category{name: ^name}} = Catalog.create_category(%{name: name})
    end

    test "create_category/1 requires a name" do
      assert {:error, changeset} = Catalog.create_category(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_category/1 enforces a unique name" do
      category_fixture(name: "Duplicate")
      assert {:error, changeset} = Catalog.create_category(%{name: "Duplicate"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "list_categories/0 returns categories" do
      category = category_fixture()
      assert category.id in Enum.map(Catalog.list_categories(), & &1.id)
    end

    test "update_category/2 and delete_category/1 (soft delete)" do
      category = category_fixture()

      assert {:ok, %Category{name: "Renamed"}} =
               Catalog.update_category(category, %{name: "Renamed"})

      assert {:ok, deleted} = Catalog.delete_category(category)
      assert deleted.deleted_at
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_category!(category.id) end
      refute category.id in Enum.map(Catalog.list_categories(), & &1.id)
      assert Zahlungs.Repo.get(Zahlungs.Catalog.Category, category.id)
    end
  end

  describe "products" do
    test "create_product/1 with valid data defaults to active" do
      assert {:ok, %Product{} = product} =
               Catalog.create_product(%{
                 sku: "A1",
                 name: "Widget",
                 price: Decimal.new("5"),
                 stock: 2
               })

      assert product.active == true
    end

    test "create_product/1 requires name (SKU is auto-generated)" do
      assert {:error, changeset} = Catalog.create_product(%{price: 1, stock: 1})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      refute Map.has_key?(errors, :sku)
    end

    test "create_product/1 enforces a unique sku" do
      product_fixture(sku: "DUP1")

      assert {:error, changeset} =
               Catalog.create_product(%{sku: "DUP1", name: "Y", price: 1, stock: 1})

      assert %{sku: ["has already been taken"]} = errors_on(changeset)
    end

    test "create_product/1 rejects negative price and stock" do
      assert {:error, changeset} =
               Catalog.create_product(%{sku: "N1", name: "Z", price: -1, stock: -1})

      errors = errors_on(changeset)
      assert "must be greater than or equal to 0" in errors.price
      assert "must be greater than or equal to 0" in errors.stock
    end

    test "create_product/1 stores purchase price and margin" do
      {:ok, product} =
        Catalog.create_product(%{
          sku: unique_sku(),
          name: "Widget",
          price: Decimal.new("1200"),
          stock: 1,
          purchase_price: Decimal.new("1000"),
          margin_percent: Decimal.new("20")
        })

      assert Decimal.equal?(product.purchase_price, Decimal.new("1000"))
      assert Decimal.equal?(product.margin_percent, Decimal.new("20"))
    end

    test "create_product/1 rejects negative purchase price and margin" do
      assert {:error, changeset} =
               Catalog.create_product(%{
                 sku: unique_sku(),
                 name: "Z",
                 price: 1,
                 stock: 1,
                 purchase_price: -1,
                 margin_percent: -5
               })

      errors = errors_on(changeset)
      assert "must be greater than or equal to 0" in errors.purchase_price
      assert "must be greater than or equal to 0" in errors.margin_percent
    end

    test "list_products/1 searches by name and sku (case-insensitive)" do
      product = product_fixture(name: "Coca Cola", sku: "COKE-1")
      _other = product_fixture(name: "Water", sku: "WTR-1")

      assert [found] = Catalog.list_products(search: "coca")
      assert found.id == product.id

      assert [found2] = Catalog.list_products(search: "coke")
      assert found2.id == product.id
    end

    test "list_products/1 filters by category" do
      category = category_fixture()
      product = product_fixture(category_id: category.id)
      _other = product_fixture()

      assert [found] = Catalog.list_products(category_id: category.id)
      assert found.id == product.id
      assert found.category.id == category.id
    end

    test "list_products/1 filters by active flag" do
      inactive = product_fixture()
      {:ok, _} = Catalog.set_product_active(inactive, false)

      active_ids = Catalog.list_products(active: true) |> Enum.map(& &1.id)
      inactive_ids = Catalog.list_products(active: false) |> Enum.map(& &1.id)

      refute inactive.id in active_ids
      assert inactive.id in inactive_ids
    end

    test "set_product_active/2 soft-deletes (deactivates)" do
      product = product_fixture()
      assert {:ok, %Product{active: false}} = Catalog.set_product_active(product, false)
    end

    test "delete_product/1 soft-deletes (hidden but row kept)" do
      product = product_fixture()
      assert {:ok, deleted} = Catalog.delete_product(product)
      assert deleted.deleted_at

      # Excluded from all queries...
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_product!(product.id) end
      refute product.id in Enum.map(Catalog.list_products(), & &1.id)

      # ...but the row still exists in the database.
      assert Zahlungs.Repo.get(Zahlungs.Catalog.Product, product.id)
    end

    test "list_low_stock_products/1 returns only low active stock" do
      _high = product_fixture(stock: 50)
      low = product_fixture(stock: 2)

      low_stock = Catalog.list_low_stock_products(5)
      assert low.id in Enum.map(low_stock, & &1.id)
      refute Enum.any?(low_stock, &(&1.stock > 5))
    end

    test "list_products/1 with in_stock excludes zero-stock products" do
      in_stock = product_fixture(stock: 5)
      out = product_fixture(stock: 0)

      ids = Catalog.list_products(in_stock: true) |> Enum.map(& &1.id)
      assert in_stock.id in ids
      refute out.id in ids
    end

    test "count_products/1 applies the same filters as list_products/1" do
      category = category_fixture()
      product_fixture(category_id: category.id)
      product_fixture(category_id: category.id)
      _other = product_fixture()

      assert Catalog.count_products(category_id: category.id) == 2
    end

    test "list_products/1 supports limit and offset for pagination" do
      category = category_fixture()
      for i <- 1..5, do: product_fixture(category_id: category.id, name: "P#{i}")

      page1 = Catalog.list_products(category_id: category.id, limit: 2, offset: 0)
      page2 = Catalog.list_products(category_id: category.id, limit: 2, offset: 2)

      assert length(page1) == 2
      assert length(page2) == 2
      assert Catalog.count_products(category_id: category.id) == 5
      # Distinct pages
      assert MapSet.disjoint?(
               MapSet.new(Enum.map(page1, & &1.id)),
               MapSet.new(Enum.map(page2, & &1.id))
             )
    end
  end

  describe "stock_report/1" do
    test "summarizes value and lists low / out-of-stock products" do
      low = product_fixture(stock: 2, price: Decimal.new("1000"), purchase_price: Decimal.new("600"))
      out = product_fixture(stock: 0, price: Decimal.new("5000"))

      report = Catalog.stock_report(5)

      assert report.products >= 2
      assert Decimal.gt?(report.cost_value, Decimal.new("0"))
      assert Decimal.gt?(report.retail_value, Decimal.new("0"))
      assert low.id in Enum.map(report.low_stock, & &1.id)
      assert out.id in Enum.map(report.out_of_stock, & &1.id)
      refute low.id in Enum.map(report.out_of_stock, & &1.id)
    end
  end

  describe "compute_price/2" do
    test "applies margin to the purchase price" do
      assert Decimal.equal?(Catalog.compute_price("1000", "20"), Decimal.new("1200.00"))
    end

    test "zero margin returns the purchase price" do
      assert Decimal.equal?(Catalog.compute_price(Decimal.new("1500"), Decimal.new("0")), Decimal.new("1500.00"))
    end

    test "blank inputs yield zero" do
      assert Decimal.equal?(Catalog.compute_price("", ""), Decimal.new("0"))
    end
  end

  describe "generate_sku/1 and barcode" do
    test "uses 3 category consonants + an incrementing counter" do
      category = category_fixture(name: "Drinks #{System.unique_integer([:positive])}")

      sku1 = Catalog.generate_sku(category.id)
      assert sku1 =~ ~r/^DRN\d{3,}$/

      # creating a product without a SKU auto-generates it
      {:ok, product} =
        Catalog.create_product(%{name: "A", price: 1, stock: 1, category_id: category.id})

      assert product.sku == sku1

      sku2 = Catalog.generate_sku(category.id)
      n1 = sku1 |> String.replace("DRN", "") |> String.to_integer()
      n2 = sku2 |> String.replace("DRN", "") |> String.to_integer()
      assert n2 == n1 + 1
    end

    test "falls back to GEN without a category" do
      assert Catalog.generate_sku(nil) =~ ~r/^GEN\d{3,}$/
    end

    test "stores barcode and makes products searchable by it" do
      barcode = "899#{System.unique_integer([:positive])}"
      product = product_fixture(barcode: barcode)

      assert product.barcode == barcode
      assert product.id in Enum.map(Catalog.list_products(search: barcode), & &1.id)
    end

    test "barcode is unique when present" do
      barcode = "899#{System.unique_integer([:positive])}"
      product_fixture(barcode: barcode)

      assert {:error, changeset} =
               Catalog.create_product(%{name: "Dup", price: 1, stock: 1, barcode: barcode})

      assert %{barcode: ["has already been taken"]} = errors_on(changeset)
    end

    test "blank barcodes are stored as nil and may repeat" do
      assert {:ok, a} = Catalog.create_product(%{name: "A", price: 1, stock: 1, barcode: ""})
      assert {:ok, b} = Catalog.create_product(%{name: "B", price: 1, stock: 1, barcode: "   "})
      assert is_nil(a.barcode)
      assert is_nil(b.barcode)
    end
  end

  describe "get_product_by_code/1 (barcode scan)" do
    test "finds an active product by barcode or SKU" do
      barcode = "899#{System.unique_integer([:positive])}"
      product = product_fixture(barcode: barcode)

      assert Catalog.get_product_by_code(barcode).id == product.id
      assert Catalog.get_product_by_code(product.sku).id == product.id
    end

    test "ignores inactive products, unknown and blank codes" do
      barcode = "899#{System.unique_integer([:positive])}"
      product = product_fixture(barcode: barcode)
      {:ok, _} = Catalog.set_product_active(product, false)

      assert is_nil(Catalog.get_product_by_code(barcode))
      assert is_nil(Catalog.get_product_by_code("nope-#{System.unique_integer([:positive])}"))
      assert is_nil(Catalog.get_product_by_code(""))
    end
  end

  describe "compute_margin/2" do
    test "derives margin from selling and purchase price" do
      assert Decimal.equal?(Catalog.compute_margin("1200", "1000"), Decimal.new("20.00"))
    end

    test "is zero when purchase price is not positive" do
      assert Decimal.equal?(Catalog.compute_margin("1200", "0"), Decimal.new("0"))
    end

    test "round-trips with compute_price" do
      price = Catalog.compute_price("1000", "35")
      assert Decimal.equal?(Catalog.compute_margin(price, "1000"), Decimal.new("35.00"))
    end
  end
end
