defmodule Zahlungs.Repo.Migrations.CreateDepositAccounts do
  use Ecto.Migration

  # PPOB (Fase 0): an owner's balance at a provider, and the one each store
  # sells services from. Accounts are deactivated, never deleted.
  def change do
    create table(:deposit_accounts) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, size: 80, null: false
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:deposit_accounts, [:organization_id, :name])

    alter table(:stores) do
      add :deposit_account_id, references(:deposit_accounts, on_delete: :restrict)
    end

    create index(:stores, [:deposit_account_id])
  end
end
