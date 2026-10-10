defmodule Zahlungs.Repo.Migrations.SnapshotConsignmentOnSaleItems do
  use Ecto.Migration

  # Whether an item was a consignment item, and whose, is fixed at the time of
  # sale — like its prices — so later edits to the product don't rewrite past
  # settlement reports.
  def change do
    alter table(:sale_items) do
      add :consignment, :boolean, null: false, default: false
      add :supplier_id, references(:suppliers, on_delete: :nilify_all)
    end

    create index(:sale_items, [:supplier_id])

    # Existing rows take the product's current values: the best record there is
    # of what they were when sold.
    execute(
      fn ->
        repo().query!("""
        UPDATE sale_items i
        JOIN products p ON p.id = i.product_id
        SET i.consignment = p.consignment, i.supplier_id = p.supplier_id
        WHERE p.consignment = 1
        """)
      end,
      fn -> :ok end
    )
  end
end
