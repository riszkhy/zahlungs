defmodule Zahlungs.Repo.Migrations.AddAdjustedAfterShiftCloseToSales do
  use Ecto.Migration

  # Set when a sale is returned or voided after its shift was already closed.
  # Such a sale still counts toward that shift's (already reconciled) figures.
  def change do
    alter table(:sales) do
      add :adjusted_after_shift_close, :boolean, null: false, default: false
    end
  end
end
