defmodule Zahlungs.Repo.Migrations.AddProviderCodeToServiceProducts do
  use Ecto.Migration

  # PPOB (Fase 1): the vendor's code for a product, needed to sell it through
  # an api deposit account.
  def change do
    alter table(:service_products) do
      add :provider_code, :string, size: 60
    end
  end
end
