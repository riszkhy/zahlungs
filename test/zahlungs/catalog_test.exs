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

    test "update_category/2 and delete_category/1" do
      category = category_fixture()

      assert {:ok, %Category{name: "Renamed"}} =
               Catalog.update_category(category, %{name: "Renamed"})

      assert {:ok, _} = Catalog.delete_category(category)
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_category!(category.id) end
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

    test "create_product/1 requires sku and name" do
      assert {:error, changeset} = Catalog.create_product(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.sku
      assert "can't be blank" in errors.name
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

    test "delete_product/1 hard-deletes" do
      product = product_fixture()
      assert {:ok, _} = Catalog.delete_product(product)
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_product!(product.id) end
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
end
