defmodule Zahlungs.Repo.Migrations.CreateSaleItems do
  use Ecto.Migration

  def change do
    create table(:sale_items) do
      add :sale_id, references(:sales, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :nilify_all)
      add :quantity, :integer, null: false
      add :unit_price, :decimal, precision: 12, scale: 2, null: false
      add :line_total, :decimal, precision: 12, scale: 2, null: false

      timestamps()
    end

    create index(:sale_items, [:sale_id])
    create index(:sale_items, [:product_id])
  end
end
