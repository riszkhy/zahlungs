defmodule Zahlungs.Repo.Migrations.AddSbiFieldsToServices do
  use Ecto.Migration

  # PPOB through Smart Biller Indonesia. An inquiry carries its own ref (a bill
  # is paid with it) and the provider's admin and total; a product keeps the
  # shop's extra fee on api bills and what the vendor last said about it; a
  # transaction keeps copies of what was sent and answered, and a review flag
  # for answers that contradict its final status.
  def change do
    alter table(:service_inquiries) do
      add :ref_id, :string, size: 32
      add :provider_admin, :decimal, precision: 15, scale: 2
      add :provider_total, :decimal, precision: 15, scale: 2
      add :details, :string, size: 120
      add :kind, :string, size: 16, null: false, default: "bill"
    end

    create unique_index(:service_inquiries, [:ref_id])

    alter table(:service_products) do
      add :api_extra_fee, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :provider_price, :decimal, precision: 15, scale: 2
      add :provider_status, :string, size: 20
      add :provider_checked_at, :naive_datetime
    end

    alter table(:service_transactions) do
      add :provider_code, :string, size: 60
      add :quoted_cost, :decimal, precision: 15, scale: 2
      add :provider_payload, :text
      add :customer_details, :string, size: 120
      add :review_reason, :string
      add :reviewed_at, :naive_datetime
      add :reviewed_by_id, references(:users, on_delete: :restrict)
    end
  end
end
