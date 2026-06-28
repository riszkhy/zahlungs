defmodule Zahlungs.CatalogFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Zahlungs.Catalog` context.
  """

  alias Zahlungs.Catalog

  def unique_sku, do: "SKU-#{System.unique_integer([:positive])}"

  def category_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "Category #{System.unique_integer([:positive])}"})
    {:ok, category} = Catalog.create_category(attrs)
    category
  end

  def product_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        sku: unique_sku(),
        name: "Product #{System.unique_integer([:positive])}",
        price: Decimal.new("1000"),
        stock: 10
      })

    {:ok, product} = Catalog.create_product(attrs)
    product
  end
end
