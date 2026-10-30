defmodule Zahlungs.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  # Piutang (kasbon): customers of an organization who may buy on credit, the
  # credit sales that name them, and their repayments (per store, like sales).
  # A customer's balance is never stored: it is computed from these rows.
  def change do
    create table(:customers) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, size: 80, null: false
      add :phone, :string, size: 20
      add :note, :string
      add :credit_limit, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:customers, [:organization_id, :name])

    alter table(:sales) do
      add :customer_id, references(:customers, on_delete: :restrict)
      add :due_date, :date
    end

    create index(:sales, [:customer_id])

    create table(:customer_payments) do
      add :customer_id, references(:customers, on_delete: :restrict), null: false
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :shift_id, references(:cashier_shifts, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :amount, :decimal, precision: 12, scale: 2, null: false
      add :payment_method, :string, size: 20, null: false
      add :note, :string
      add :cancelled_at, :naive_datetime
      add :cancelled_by_id, references(:users, on_delete: :nilify_all)
      add :cancel_reason, :string

      timestamps()
    end

    create index(:customer_payments, [:customer_id])
    create index(:customer_payments, [:shift_id])

    alter table(:cash_movements) do
      add :customer_id, references(:customers, on_delete: :nilify_all)
    end

    create index(:cash_movements, [:customer_id])
  end
end
