defmodule Zahlungs.Repo.Migrations.AddSoftDeleteToCatalog do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :deleted_at, :naive_datetime
    end

    alter table(:categories) do
      add :deleted_at, :naive_datetime
    end

    create index(:products, [:deleted_at])
    create index(:categories, [:deleted_at])
  end
end
