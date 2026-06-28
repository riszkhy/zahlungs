defmodule Zahlungs.Repo.Migrations.AddBarcodeToProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :barcode, :string
    end

    create index(:products, [:barcode])
  end
end
