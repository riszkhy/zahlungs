defmodule Zahlungs.Repo.Migrations.AddActiveToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :active, :boolean, null: false, default: true
    end
  end
end
