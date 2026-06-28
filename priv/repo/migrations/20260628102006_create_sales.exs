defmodule Zahlungs.Repo.Migrations.CreateSales do
  use Ecto.Migration

  def change do
    create table(:sales) do
      add :code, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :subtotal, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :discount, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :tax, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :total, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :amount_paid, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :change_due, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :status, :string, null: false, default: "completed"

      timestamps()
    end

    create unique_index(:sales, [:code])
    create index(:sales, [:user_id])
    create index(:sales, [:inserted_at])
  end
end
