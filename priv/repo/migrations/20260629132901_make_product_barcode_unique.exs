defmodule Zahlungs.Repo.Migrations.MakeProductBarcodeUnique do
  use Ecto.Migration

  def up do
    # Normalize any empty-string barcodes to NULL so the unique index allows
    # multiple "blank" barcodes (MySQL treats NULLs as distinct).
    execute("UPDATE products SET barcode = NULL WHERE barcode = ''")

    drop index(:products, [:barcode])
    create unique_index(:products, [:barcode])
  end

  def down do
    drop index(:products, [:barcode])
    create index(:products, [:barcode])
  end
end
