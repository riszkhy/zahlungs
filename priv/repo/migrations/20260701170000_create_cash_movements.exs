defmodule Zahlungs.Repo.Migrations.CreateCashMovements do
  use Ecto.Migration

  def change do
    create table(:cash_movements) do
      add :shift_id, references(:cashier_shifts, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :supplier_id, references(:suppliers, on_delete: :nilify_all)
      add :direction, :string, null: false
      add :category, :string, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :note, :string

      timestamps()
    end

    create index(:cash_movements, [:shift_id])
    create index(:cash_movements, [:supplier_id])
  end
end
