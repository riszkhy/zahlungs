defmodule Zahlungs.Sales.SaleItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sale_items" do
    field :quantity, :integer
    field :unit_price, :decimal
    field :line_total, :decimal
    field :purchase_price, :decimal, default: Decimal.new(0)

    belongs_to :sale, Zahlungs.Sales.Sale
    belongs_to :product, Zahlungs.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:sale_id, :product_id, :quantity, :unit_price, :line_total, :purchase_price])
    |> validate_required([:quantity, :unit_price, :line_total])
    |> validate_number(:quantity, greater_than: 0)
  end
end
