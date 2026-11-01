defmodule Zahlungs.Repo.Migrations.CreateServiceCommissions do
  use Ecto.Migration

  # Cashier commission on services: a percent of the margin per category, set
  # by the organization's admin, and the percent a service was recorded with
  # (0 for services recorded before this, and for those an admin records).
  # The amount is never stored: it follows the service's final status and cost.
  def change do
    create table(:service_commission_rates) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :category, :string, size: 20, null: false
      add :percent, :decimal, precision: 5, scale: 2, null: false, default: 0

      timestamps()
    end

    create unique_index(:service_commission_rates, [:organization_id, :category])

    alter table(:service_transactions) do
      add :commission_percent, :decimal, precision: 5, scale: 2, null: false, default: 0
    end
  end
end
