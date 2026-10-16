defmodule Zahlungs.Repo.Migrations.CreateServiceTransactions do
  use Ecto.Migration

  # PPOB (Fase 0): one service sold, recorded when the money is taken
  # (processing) and then marked success or failed. Belongs to a store and its
  # shift, like a sale; the product's price and cost are copied at the time.
  def change do
    create table(:service_transactions) do
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :shift_id, references(:cashier_shifts, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :service_product_id, references(:service_products, on_delete: :restrict), null: false
      add :deposit_account_id, references(:deposit_accounts, on_delete: :restrict), null: false
      add :code, :string, null: false
      add :category, :string, null: false
      add :product_name, :string, size: 160, null: false
      add :customer_ref, :string, size: 20, null: false
      add :bill_amount, :decimal, precision: 15, scale: 2
      add :price, :decimal, precision: 15, scale: 2, null: false
      add :cost, :decimal, precision: 15, scale: 2, null: false
      add :payment_method, :string, null: false, default: "cash"
      add :amount_paid, :decimal, precision: 15, scale: 2, null: false
      add :change_due, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :status, :string, null: false, default: "processing"
      add :token_sn, :string, size: 64
      add :failure_reason, :string
      add :resolved_by_id, references(:users, on_delete: :restrict)
      add :resolved_at, :naive_datetime

      timestamps()
    end

    create unique_index(:service_transactions, [:store_id, :code])
    create index(:service_transactions, [:shift_id, :status])
    create index(:service_transactions, [:deposit_account_id, :status])
  end
end
