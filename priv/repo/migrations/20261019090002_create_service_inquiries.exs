defmodule Zahlungs.Repo.Migrations.CreateServiceInquiries do
  use Ecto.Migration

  # PPOB (Fase 1): what the provider said about a PLN bill — kept on the server
  # for 15 minutes and used once, so the amount paid never comes from the
  # browser. Belongs to a store, like a sale.
  def change do
    create table(:service_inquiries) do
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :service_product_id, references(:service_products, on_delete: :restrict), null: false
      add :deposit_account_id, references(:deposit_accounts, on_delete: :restrict), null: false
      add :customer_ref, :string, size: 20, null: false
      add :customer_name, :string, size: 120
      add :period, :string, size: 60
      add :sheets, :integer, null: false, default: 1
      add :bill_amount, :decimal, precision: 15, scale: 2, null: false
      add :inquiry_ref, :string
      add :expires_at, :naive_datetime, null: false
      add :used_at, :naive_datetime

      timestamps()
    end

    create index(:service_inquiries, [:store_id, :inserted_at])
  end
end
