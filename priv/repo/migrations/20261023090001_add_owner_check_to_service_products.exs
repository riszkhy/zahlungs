defmodule Zahlungs.Repo.Migrations.AddOwnerCheckToServiceProducts do
  use Ecto.Migration

  # Token PLN through an api account: check the meter's owner first (true, as
  # before), or buy it directly like pulsa.
  def change do
    alter table(:service_products) do
      add :owner_check, :boolean, null: false, default: true
    end
  end
end
