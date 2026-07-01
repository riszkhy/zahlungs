defmodule Zahlungs.Repo.Migrations.AddShiftIdToSales do
  use Ecto.Migration

  def change do
    alter table(:sales) do
      add :shift_id, references(:cashier_shifts, on_delete: :nilify_all)
    end

    create index(:sales, [:shift_id])
  end
end
