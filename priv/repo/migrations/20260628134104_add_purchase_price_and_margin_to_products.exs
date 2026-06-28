defmodule Zahlungs.Repo.Migrations.AddPurchasePriceAndMarginToProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :purchase_price, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :margin_percent, :decimal, precision: 7, scale: 2, null: false, default: 0
    end
  end
end
