defmodule Zahlungs.Repo.Migrations.AddVoidToSales do
  use Ecto.Migration

  def change do
    alter table(:sales) do
      add :voided_at, :naive_datetime
      add :void_reason, :string
      add :voided_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:sales, [:voided_by_id])
  end
end
