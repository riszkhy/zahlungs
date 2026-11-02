defmodule Zahlungs.Repo.Migrations.AddRupiahToServiceCommissions do
  use Ecto.Migration

  # A category's commission is a percent of the margin or a rupiah amount per
  # service. A service copies whichever it is; the other stays 0.
  def change do
    alter table(:service_commission_rates) do
      add :kind, :string, size: 10, null: false, default: "percent"
      add :amount, :decimal, precision: 12, scale: 2, null: false, default: 0
    end

    alter table(:service_transactions) do
      add :commission_amount, :decimal, precision: 12, scale: 2, null: false, default: 0
    end
  end
end
