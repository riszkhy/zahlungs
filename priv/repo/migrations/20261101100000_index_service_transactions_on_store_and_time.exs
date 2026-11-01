defmodule Zahlungs.Repo.Migrations.IndexServiceTransactionsOnStoreAndTime do
  use Ecto.Migration

  # Riwayat layanan lists a store's services by date, newest first.
  def change do
    create index(:service_transactions, [:store_id, :inserted_at])
  end
end
