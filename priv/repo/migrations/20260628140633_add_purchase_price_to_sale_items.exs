defmodule Zahlungs.Repo.Migrations.AddPurchasePriceToSaleItems do
  use Ecto.Migration

  def change do
    alter table(:sale_items) do
      add :purchase_price, :decimal, precision: 12, scale: 2, null: false, default: 0
    end
  end
end
