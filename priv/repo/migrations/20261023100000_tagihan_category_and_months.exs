defmodule Zahlungs.Repo.Migrations.TagihanCategoryAndMonths do
  use Ecto.Migration

  # One "Tagihan" category for every bill (PLN, BPJS, PDAM, ...) replaces
  # "Tagihan PLN"; a product may ask how many months are paid at once, and an
  # inquiry remembers the answer.
  def change do
    alter table(:service_products) do
      add :ask_months, :boolean, null: false, default: false
    end

    alter table(:service_inquiries) do
      add :months, :integer
    end

    execute(
      "UPDATE service_products SET category = 'tagihan' WHERE category = 'tagihan_pln'",
      "UPDATE service_products SET category = 'tagihan_pln' WHERE category = 'tagihan'"
    )

    execute(
      "UPDATE service_transactions SET category = 'tagihan' WHERE category = 'tagihan_pln'",
      "UPDATE service_transactions SET category = 'tagihan_pln' WHERE category = 'tagihan'"
    )
  end
end
