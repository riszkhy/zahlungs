defmodule Zahlungs.Repo.Migrations.CreateServiceProducts do
  use Ecto.Migration

  # PPOB (Fase 0): what a store sells besides goods — pulsa, paket data,
  # token PLN, tagihan PLN. No stock: the price is the cost plus a margin.
  def change do
    create table(:service_products) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, size: 160, null: false
      add :category, :string, null: false
      add :operator, :string, size: 60
      # For tagihan_pln: the provider's fee on top of the bill.
      add :cost, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :margin_type, :string, null: false, default: "amount"
      add :margin_value, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :deleted_at, :naive_datetime

      timestamps()
    end

    create index(:service_products, [:organization_id, :category])
  end
end
