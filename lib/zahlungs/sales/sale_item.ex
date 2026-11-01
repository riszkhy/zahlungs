defmodule Zahlungs.Sales.SaleItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sale_items" do
    field :quantity, :integer
    field :unit_price, :decimal
    field :line_total, :decimal
    field :purchase_price, :decimal, default: Decimal.new(0)
    # Snapshot of the product at the time of sale, like the prices above.
    field :consignment, :boolean, default: false
    # The promotion's discount on this line, and which one gave it (its name
    # copied, like the prices). line_total = unit_price × quantity − discount.
    field :discount, :decimal, default: Decimal.new(0)
    field :promotion_name, :string

    belongs_to :sale, Zahlungs.Sales.Sale
    belongs_to :product, Zahlungs.Catalog.Product
    belongs_to :supplier, Zahlungs.Catalog.Supplier
    belongs_to :promotion, Zahlungs.Promotions.Promotion

    timestamps()
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :sale_id,
      :product_id,
      :quantity,
      :unit_price,
      :line_total,
      :purchase_price,
      :consignment,
      :supplier_id,
      :discount,
      :promotion_id,
      :promotion_name
    ])
    |> validate_required([:quantity, :unit_price, :line_total])
    |> validate_number(:quantity, greater_than: 0)
  end
end
