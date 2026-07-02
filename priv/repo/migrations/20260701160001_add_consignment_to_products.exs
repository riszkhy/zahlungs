defmodule Zahlungs.Repo.Migrations.AddConsignmentToProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :consignment, :boolean, null: false, default: false
      add :supplier_id, references(:suppliers, on_delete: :nilify_all)
    end

    create index(:products, [:supplier_id])
  end
end
