defmodule Zahlungs.Repo.Migrations.AddPaymentMethodToSales do
  use Ecto.Migration

  def change do
    alter table(:sales) do
      add :payment_method, :string, null: false, default: "cash"
    end
  end
end
