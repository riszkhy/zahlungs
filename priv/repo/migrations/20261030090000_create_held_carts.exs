defmodule Zahlungs.Repo.Migrations.CreateHeldCarts do
  use Ecto.Migration

  # Carts the cashier put aside (Tunda) to resume later, per store like sales,
  # so without organization_id. Prices and stock are not kept: a resumed cart
  # reads them again.
  def change do
    create table(:held_carts) do
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :shift_id, references(:cashier_shifts, on_delete: :nilify_all)
      add :note, :string, size: 60
      add :discount, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :tax, :decimal, precision: 12, scale: 2, null: false, default: 0

      timestamps()
    end

    create index(:held_carts, [:store_id, :inserted_at])

    create table(:held_cart_items) do
      add :held_cart_id, references(:held_carts, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :restrict), null: false
      add :quantity, :integer, null: false
      add :name, :string, null: false

      timestamps()
    end

    create index(:held_cart_items, [:held_cart_id])
  end
end
