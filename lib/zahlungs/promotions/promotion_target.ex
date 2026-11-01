defmodule Zahlungs.Promotions.PromotionTarget do
  use Ecto.Schema

  # What a promotion applies to: one product or one category per row.
  schema "promotion_targets" do
    belongs_to :promotion, Zahlungs.Promotions.Promotion
    belongs_to :product, Zahlungs.Catalog.Product
    belongs_to :category, Zahlungs.Catalog.Category
  end
end
