defmodule Zahlungs.Repo.Migrations.AllowInquiriesWithoutABill do
  use Ecto.Migration

  # A token PLN owner check (kind "customer") is an inquiry with no amount.
  def change do
    alter table(:service_inquiries) do
      modify :bill_amount, :decimal,
        precision: 15,
        scale: 2,
        null: true,
        from: {:decimal, precision: 15, scale: 2, null: false}
    end
  end
end
