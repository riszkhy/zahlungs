defmodule Zahlungs.Repo.Migrations.AddApiModeToDepositAccounts do
  use Ecto.Migration

  # PPOB (Fase 1): an account is either manual (Fase 0: the cashier works in
  # the provider's own app) or api (Zahlungs talks to the provider). An api
  # account keeps its credentials encrypted and a random token for the
  # provider's callback URL.
  def change do
    alter table(:deposit_accounts) do
      add :mode, :string, null: false, default: "manual"
      add :provider, :string
      add :credentials, :binary
      add :callback_token, :string
    end

    create unique_index(:deposit_accounts, [:callback_token])
  end
end
