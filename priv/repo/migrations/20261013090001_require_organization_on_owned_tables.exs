defmodule Zahlungs.Repo.Migrations.RequireOrganizationOnOwnedTables do
  use Ecto.Migration

  # Separate from the backfill so a failure here cannot leave that half-applied.
  # users and user_logins stay nullable: the platform operator belongs to no
  # organization.
  @required [:stores, :categories, :suppliers, :products]

  def up do
    for table <- @required do
      execute "ALTER TABLE #{table} MODIFY organization_id BIGINT UNSIGNED NOT NULL"
    end
  end

  def down do
    for table <- @required do
      execute "ALTER TABLE #{table} MODIFY organization_id BIGINT UNSIGNED NULL"
    end
  end
end
