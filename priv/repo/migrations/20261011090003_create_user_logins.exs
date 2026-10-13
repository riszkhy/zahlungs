defmodule Zahlungs.Repo.Migrations.CreateUserLogins do
  use Ecto.Migration

  # Append-only log of successful logins and where they were made from.
  def change do
    create table(:user_logins) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :store_id, references(:stores, on_delete: :nilify_all)
      add :latitude, :float
      add :longitude, :float
      add :accuracy_m, :float
      add :distance_m, :float
      add :ip, :string, size: 64
      add :user_agent, :string

      timestamps(updated_at: false)
    end

    create index(:user_logins, [:user_id, :inserted_at])
    create index(:user_logins, [:store_id, :inserted_at])
    create index(:user_logins, [:inserted_at])
  end
end
