defmodule Zahlungs.Catalog.ProductStock do
  @moduledoc "Units of a product on hand in one store. No row means zero."
  use Ecto.Schema

  schema "product_stocks" do
    field :stock, :integer, default: 0

    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :product, Zahlungs.Catalog.Product

    timestamps()
  end
end
