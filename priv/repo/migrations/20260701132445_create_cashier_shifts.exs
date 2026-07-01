defmodule Zahlungs.Repo.Migrations.CreateCashierShifts do
  use Ecto.Migration

  def change do
    create table(:cashier_shifts) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :status, :string, null: false, default: "open"
      add :opening_cash, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :expected_cash, :decimal, precision: 12, scale: 2
      add :counted_cash, :decimal, precision: 12, scale: 2
      add :variance, :decimal, precision: 12, scale: 2
      add :opened_at, :naive_datetime, null: false
      add :closed_at, :naive_datetime
      add :note, :text

      timestamps()
    end

    create index(:cashier_shifts, [:user_id])
    create index(:cashier_shifts, [:status])
  end
end
