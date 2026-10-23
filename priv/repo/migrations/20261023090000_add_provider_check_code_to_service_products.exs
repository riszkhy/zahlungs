defmodule Zahlungs.Repo.Migrations.AddProviderCheckCodeToServiceProducts do
  use Ecto.Migration

  # Token PLN: the vendor's code for the owner check before a sale (SBI's
  # default is CPLNPRA, which not every member's price plan includes).
  def change do
    alter table(:service_products) do
      add :provider_check_code, :string, size: 60
    end
  end
end
