defmodule Zahlungs.Repo.Migrations.ChangeUsersTokensTokenToBinary do
  use Ecto.Migration

  # Tokens are raw binary (SHA-256 hashes and random bytes). They were originally
  # declared as `:string`, which corrupts binary data on MySQL/MariaDB. Convert the
  # column to VARBINARY. Existing token rows are ephemeral (sessions / one-time
  # email tokens) and may already be corrupted, so we clear them.
  @index "users_tokens_context_token_index"

  def up do
    execute "DELETE FROM users_tokens"
    execute "DROP INDEX #{@index} ON users_tokens"
    execute "ALTER TABLE users_tokens MODIFY token VARBINARY(255) NOT NULL"
    execute "CREATE UNIQUE INDEX #{@index} ON users_tokens (context, token)"
  end

  def down do
    execute "DROP INDEX #{@index} ON users_tokens"
    execute "ALTER TABLE users_tokens MODIFY token VARCHAR(255) NOT NULL"
    execute "CREATE UNIQUE INDEX #{@index} ON users_tokens (context, token)"
  end
end
