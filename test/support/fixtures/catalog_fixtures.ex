defmodule Zahlungs.CatalogFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Zahlungs.Catalog` context.
  """

  alias Zahlungs.Catalog

  def unique_sku, do: "SKU-#{System.unique_integer([:positive])}"

  def category_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()
    attrs = Enum.into(attrs, %{name: "Category #{System.unique_integer([:positive])}"})
    {:ok, category} = Catalog.create_category(attrs)
    category
  end

  def supplier_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()
    attrs = Enum.into(attrs, %{name: "Supplier #{System.unique_integer([:positive])}"})
    {:ok, supplier} = Catalog.create_supplier(attrs)
    supplier
  end

  def product_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        sku: unique_sku(),
        name: "Product #{System.unique_integer([:positive])}",
        price: Decimal.new("1000"),
        stock: 10
      })

    {:ok, product} = Catalog.create_product(Zahlungs.StoresFixtures.store_scope(), attrs)
    product
  end

  @doc "Units of the product on hand in a store (the test's default store unless given)."
  def stock_of(product, store \\ nil) do
    Catalog.get_product!(Zahlungs.StoresFixtures.store_scope(store), product.id).stock
  end
end
