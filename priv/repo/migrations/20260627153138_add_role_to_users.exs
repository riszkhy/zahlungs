defmodule Zahlungs.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :role, :string, null: false, default: "cashier"
    end

    create index(:users, [:role])
  end
end
