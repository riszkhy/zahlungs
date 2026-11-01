defmodule Zahlungs.Promotions.PromotionStore do
  use Ecto.Schema

  # A store a promotion runs in, when it doesn't run in all of them.
  schema "promotion_stores" do
    belongs_to :promotion, Zahlungs.Promotions.Promotion
    belongs_to :store, Zahlungs.Stores.Store
  end
end
