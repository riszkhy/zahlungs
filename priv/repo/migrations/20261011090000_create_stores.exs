defmodule Zahlungs.Repo.Migrations.CreateStores do
  use Ecto.Migration

  # Multi-store: one owner, several branches. Users belong to a store, and every
  # shift and sale happens in one. Existing data moves into a default store.
  def up do
    create table(:stores) do
      add :name, :string, null: false
      add :code, :string, null: false, size: 12
      add :address, :string
      add :phone, :string
      add :utc_offset_hours, :integer, null: false, default: 7
      add :latitude, :float
      add :longitude, :float
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:stores, [:code])

    alter table(:users) do
      add :store_id, references(:stores, on_delete: :nilify_all)
    end

    alter table(:cashier_shifts) do
      add :store_id, references(:stores, on_delete: :restrict)
    end

    alter table(:sales) do
      add :store_id, references(:stores, on_delete: :restrict)
    end

    create index(:users, [:store_id])
    create index(:cashier_shifts, [:store_id, :status])
    create index(:sales, [:store_id, :inserted_at])

    flush()

    repo().query!("""
    INSERT INTO stores (name, code, utc_offset_hours, active, inserted_at, updated_at)
    VALUES ('Toko Utama', 'TU', 7, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP())
    """)

    # Cashiers work in a store; admins (the owner) are not tied to one.
    repo().query!(
      "UPDATE users SET store_id = (SELECT MIN(id) FROM stores) WHERE role = 'cashier'"
    )

    repo().query!("UPDATE cashier_shifts SET store_id = (SELECT MIN(id) FROM stores)")
    repo().query!("UPDATE sales SET store_id = (SELECT MIN(id) FROM stores)")
  end

  def down do
    drop constraint(:sales, "sales_store_id_fkey")
    drop constraint(:cashier_shifts, "cashier_shifts_store_id_fkey")
    drop constraint(:users, "users_store_id_fkey")

    drop index(:sales, [:store_id, :inserted_at])
    drop index(:cashier_shifts, [:store_id, :status])
    drop index(:users, [:store_id])

    alter table(:sales), do: remove(:store_id)
    alter table(:cashier_shifts), do: remove(:store_id)
    alter table(:users), do: remove(:store_id)

    drop table(:stores)
  end
end
