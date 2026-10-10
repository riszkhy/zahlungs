import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :zahlungs, Zahlungs.Repo,
    # socket_options: [:inet6],
    url: database_url,
    ssl: System.get_env("DATABASE_SSL") in ~w(true 1),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Shop time zone as a fixed UTC offset in hours (default 7 = WIB).
  if utc_offset = System.get_env("UTC_OFFSET_HOURS") do
    config :zahlungs, :utc_offset_hours, String.to_integer(utc_offset)
  end

  # Sender of the account emails, e.g. MAIL_FROM="kasir@tokosaya.id".
  if mail_from = System.get_env("MAIL_FROM") do
    config :zahlungs, :mail_from, {"Zahlungs", mail_from}
  end

  # Public host used for generated URLs (links in emails, redirects, ~p URLs).
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # When FORCE_SSL is on, the app assumes it sits behind a TLS-terminating
  # reverse proxy (nginx/caddy/traefik): generated URLs use https and plain
  # HTTP requests are redirected (trusting the x-forwarded-proto header).
  force_ssl? = System.get_env("FORCE_SSL") in ~w(true 1)

  url_config =
    if force_ssl?, do: [host: host, port: 443, scheme: "https"], else: [host: host, port: port]

  config :zahlungs, ZahlungsWeb.Endpoint,
    url: url_config,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  if force_ssl? do
    config :zahlungs, ZahlungsWeb.Endpoint,
      force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]
  end

  # Optional HTTPS listener served by the app itself (no reverse proxy). This is
  # what a LAN POS deployment needs: the phone-camera barcode scanner uses
  # getUserMedia/BarcodeDetector, which browsers only allow in a secure context
  # (HTTPS or localhost) — over plain HTTP to a LAN IP the camera stays off.
  #
  # Set HTTPS_PORT + SSL_CERT_PATH + SSL_KEY_PATH (absolute paths to a cert and
  # key; a self-signed pair from `mix phx.gen.cert` works on a private LAN).
  # Leave these unset when TLS is terminated by a reverse proxy (use FORCE_SSL).
  https_port = System.get_env("HTTPS_PORT")
  ssl_certfile = System.get_env("SSL_CERT_PATH")
  ssl_keyfile = System.get_env("SSL_KEY_PATH")

  if https_port && ssl_certfile && ssl_keyfile do
    config :zahlungs, ZahlungsWeb.Endpoint,
      https: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(https_port),
        cipher_suite: :strong,
        certfile: ssl_certfile,
        keyfile: ssl_keyfile
      ]
  end

  # ## Mailer
  #
  # No mail adapter is configured here: the default `Local` adapter keeps
  # messages in memory, so in production nothing is delivered. The app knows
  # this (`Zahlungs.Mailer.delivers?/0`): it logs a warning at boot and hides
  # the "Forgot password?" link; admins reset passwords at /admin/users.
  #
  # To send real email, add an adapter and its dependency. For SMTP, add
  # `{:gen_smtp, "~> 1.2"}` to mix.exs and configure:
  #
  #     config :zahlungs, Zahlungs.Mailer,
  #       adapter: Swoosh.Adapters.SMTP,
  #       relay: System.fetch_env!("SMTP_HOST"),
  #       port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
  #       username: System.fetch_env!("SMTP_USERNAME"),
  #       password: System.fetch_env!("SMTP_PASSWORD"),
  #       tls: :always
  #
  # See docs/DEPLOYMENT.md and https://hexdocs.pm/swoosh/Swoosh.Adapters.SMTP.html.
end
