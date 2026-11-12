defmodule Zahlungs.Repo.Migrations.AddCorrectionToServiceTransactions do
  use Ecto.Migration

  # An admin's last correction of a final status: when, by whom, and why.
  def change do
    alter table(:service_transactions) do
      add :corrected_at, :naive_datetime
      add :corrected_by_id, references(:users, on_delete: :nilify_all)
      add :correction_reason, :string, size: 200
    end
  end
end
