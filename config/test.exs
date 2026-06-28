import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database (MariaDB, via the myxql adapter).
#
# Tests use the Ecto SQL Sandbox: each test runs inside a transaction that is
# rolled back afterwards, so the database is never mutated. Real credentials are
# NOT committed — they come from env vars (safe localhost defaults) and/or the
# gitignored `config/local.secret.exs` imported at the bottom of this file.
config :zahlungs, Zahlungs.Repo,
  username: System.get_env("DB_USERNAME", "root"),
  password: System.get_env("DB_PASSWORD", ""),
  database: System.get_env("DB_TEST_NAME", System.get_env("DB_NAME", "zahlungs")),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "3306")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  # The dev/test DB may be a high-latency remote (≈100–400ms/query). Let the
  # connection pool wait for a slot instead of dropping checkouts, so async
  # tests don't fail spuriously with DBConnection.ConnectionError.
  queue_target: 5_000,
  queue_interval: 30_000,
  timeout: 30_000,
  ownership_timeout: 120_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :zahlungs, ZahlungsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jO/W+G/Qx2j1vaL3e08mem3yYnkgOD2lRNuZaK4/cT17Ehpo5rrUoOGigq5RjxOu",
  server: false

# In test we don't send emails.
config :zahlungs, Zahlungs.Mailer, adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Import local, gitignored credentials (real DB username/password/host/etc) if present.
if File.exists?(Path.expand("local.secret.exs", __DIR__)) do
  import_config "local.secret.exs"
end
