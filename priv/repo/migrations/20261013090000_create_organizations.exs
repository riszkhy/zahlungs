defmodule Zahlungs.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  # SaaS: several owners (organizations) share one database. Everything an
  # owner has - stores, users, catalog - carries an organization_id, and codes
  # that used to be unique in the whole application become unique per owner.
  # Existing data moves into one default organization.

  @owned [:stores, :users, :categories, :suppliers, :products, :user_logins]

  def up do
    create table(:organizations) do
      add :name, :string, null: false
      add :phone, :string
      # pending -> active (approved) | rejected; active <-> suspended
      add :status, :string, null: false, default: "pending"
      add :reviewed_at, :naive_datetime
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :review_note, :string
      # Billing is manual: the platform operator records what was agreed.
      add :paid_until, :date
      add :billing_note, :string

      timestamps()
    end

    create index(:organizations, [:status])

    for table <- @owned do
      alter table(table) do
        add :organization_id, references(:organizations, on_delete: :restrict)
      end
    end

    flush()

    repo().query!("""
    INSERT INTO organizations (name, status, reviewed_at, inserted_at, updated_at)
    VALUES ('Organisasi Utama', 'active', UTC_TIMESTAMP(), UTC_TIMESTAMP(), UTC_TIMESTAMP())
    """)

    for table <- @owned do
      repo().query!("UPDATE #{table} SET organization_id = (SELECT MIN(id) FROM organizations)")
    end

    drop unique_index(:products, [:sku])
    drop unique_index(:products, [:barcode])
    drop unique_index(:categories, [:name])
    drop unique_index(:stores, [:code])
    drop unique_index(:sales, [:code])

    create unique_index(:products, [:organization_id, :sku])
    create unique_index(:products, [:organization_id, :barcode])
    create unique_index(:categories, [:organization_id, :name])
    create unique_index(:stores, [:organization_id, :code])
    # Invoice codes start with the store code, which is now only unique per owner.
    create unique_index(:sales, [:store_id, :code])
  end

  def down do
    drop unique_index(:sales, [:store_id, :code])
    drop unique_index(:stores, [:organization_id, :code])
    drop unique_index(:categories, [:organization_id, :name])
    drop unique_index(:products, [:organization_id, :barcode])
    drop unique_index(:products, [:organization_id, :sku])

    create unique_index(:sales, [:code])
    create unique_index(:stores, [:code])
    create unique_index(:categories, [:name])
    create unique_index(:products, [:barcode])
    create unique_index(:products, [:sku])

    for table <- @owned do
      drop constraint(table, "#{table}_organization_id_fkey")

      alter table(table) do
        remove :organization_id
      end
    end

    drop table(:organizations)
  end
end
