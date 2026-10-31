defmodule Zahlungs.Repo.Migrations.CreatePromotions do
  use Ecto.Migration

  # Promotions (sub-project 1): a percent or rupiah discount on products or
  # categories for a date range, in all stores or chosen ones. Each sale line
  # keeps the discount it got and which promotion gave it; line_total is net.
  def change do
    create table(:promotions) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, size: 80, null: false
      add :kind, :string, size: 10, null: false
      add :value, :decimal, precision: 12, scale: 2, null: false
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false
      add :all_stores, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create index(:promotions, [:organization_id, :ends_on])

    create table(:promotion_targets) do
      add :promotion_id, references(:promotions, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :delete_all)
      add :category_id, references(:categories, on_delete: :delete_all)
    end

    create index(:promotion_targets, [:promotion_id])

    create table(:promotion_stores) do
      add :promotion_id, references(:promotions, on_delete: :delete_all), null: false
      add :store_id, references(:stores, on_delete: :delete_all), null: false
    end

    create unique_index(:promotion_stores, [:promotion_id, :store_id])

    alter table(:sale_items) do
      add :discount, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :promotion_id, references(:promotions, on_delete: :nilify_all)
      add :promotion_name, :string, size: 80
    end

    create index(:sale_items, [:promotion_id])

    alter table(:organizations) do
      add :max_cashier_discount_percent, :decimal, precision: 5, scale: 2
    end
  end
end
