defmodule Zahlungs.Repo.Migrations.AddApiFieldsToServiceTransactions do
  use Ecto.Migration

  # PPOB (Fase 1): a transaction sent to the provider. `channel` is the
  # account's mode when it was recorded; `ref_id` is what the provider knows it
  # by; `sent_at` is set just before it is sent, so a service never sent can be
  # told from one the provider may have; refunds of failed api services are
  # confirmed by a cashier.
  def change do
    alter table(:service_transactions) do
      add :channel, :string, null: false, default: "manual"
      add :ref_id, :string
      add :provider_ref, :string
      add :provider_message, :string
      add :sent_at, :naive_datetime
      add :last_checked_at, :naive_datetime
      add :sheets, :integer, null: false, default: 1
      add :customer_name, :string, size: 120
      add :period, :string, size: 60
      add :service_inquiry_id, references(:service_inquiries, on_delete: :restrict)
      add :failed_after_shift_close, :boolean, null: false, default: false
      add :refunded_at, :naive_datetime
      add :refunded_by_id, references(:users, on_delete: :restrict)
    end

    create unique_index(:service_transactions, [:ref_id])
    create index(:service_transactions, [:channel, :status])
  end
end
