defmodule Zahlungs.Repo.Migrations.CreateSuppliers do
  use Ecto.Migration

  def change do
    create table(:suppliers) do
      add :name, :string, null: false
      add :phone, :string
      add :note, :string
      add :deleted_at, :naive_datetime

      timestamps()
    end
  end
end
