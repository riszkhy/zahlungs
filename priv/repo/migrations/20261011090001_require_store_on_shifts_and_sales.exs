defmodule Zahlungs.Repo.Migrations.RequireStoreOnShiftsAndSales do
  use Ecto.Migration

  # Separate from the backfill so a failure here can't leave that half-applied.
  def up do
    execute "ALTER TABLE cashier_shifts MODIFY store_id BIGINT UNSIGNED NOT NULL"
    execute "ALTER TABLE sales MODIFY store_id BIGINT UNSIGNED NOT NULL"
  end

  def down do
    execute "ALTER TABLE cashier_shifts MODIFY store_id BIGINT UNSIGNED NULL"
    execute "ALTER TABLE sales MODIFY store_id BIGINT UNSIGNED NULL"
  end
end
