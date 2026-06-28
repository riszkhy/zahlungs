defmodule Zahlungs.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :sku, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :image_url, :string
      add :price, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :stock, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :category_id, references(:categories, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:products, [:sku])
    create index(:products, [:category_id])
    create index(:products, [:active])
  end
end
