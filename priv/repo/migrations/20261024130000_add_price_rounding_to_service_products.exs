defmodule Zahlungs.Repo.Migrations.AddPriceRoundingToServiceProducts do
  use Ecto.Migration

  # The price to the customer is rounded up to this multiple of rupiah
  # (0 = not rounded, as before; 100, 500 or 1000).
  def change do
    alter table(:service_products) do
      add :price_rounding, :integer, null: false, default: 0
    end
  end
end
