defmodule Zahlungs.Repo.Migrations.AddReturnedAtToSales do
  use Ecto.Migration

  def change do
    alter table(:sales) do
      add :returned_at, :naive_datetime
    end
  end
end
