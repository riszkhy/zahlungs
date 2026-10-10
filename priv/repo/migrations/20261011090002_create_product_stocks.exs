defmodule Zahlungs.Repo.Migrations.CreateProductStocks do
  use Ecto.Migration

  # Stock is per store. `products.stock` is left in place, unused, and dropped
  # in a later release once nothing reads it.
  def up do
    create table(:product_stocks) do
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :stock, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:product_stocks, [:store_id, :product_id])
    create index(:product_stocks, [:product_id])

    flush()

    repo().query!("""
    INSERT INTO product_stocks (store_id, product_id, stock, inserted_at, updated_at)
    SELECT (SELECT MIN(id) FROM stores), p.id, p.stock, UTC_TIMESTAMP(), UTC_TIMESTAMP()
    FROM products p
    """)
  end

  def down do
    drop table(:product_stocks)
  end
end
