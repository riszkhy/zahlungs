defmodule Zahlungs.Repo.Migrations.CreateDepositEntries do
  use Ecto.Migration

  # PPOB (Fase 0): what goes into a deposit account (top-ups, from the drawer or
  # from outside it) and corrections, including the difference found when the
  # admin reconciles with the provider's balance.
  def change do
    create table(:deposit_entries) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :deposit_account_id, references(:deposit_accounts, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :source, :string
      add :note, :string
      add :cash_movement_id, references(:cash_movements, on_delete: :restrict)
      add :recorded_by_id, references(:users, on_delete: :restrict), null: false

      timestamps()
    end

    create index(:deposit_entries, [:deposit_account_id])
  end
end
