# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :zahlungs,
  ecto_repos: [Zahlungs.Repo]

# Shop time zone as a fixed UTC offset in hours (7 = WIB, 8 = WITA, 9 = WIT).
# Timestamps are stored in UTC; this decides where "today" starts and how
# times are shown. See Zahlungs.LocalTime.
config :zahlungs, :utc_offset_hours, 7

# Configures the endpoint
config :zahlungs, ZahlungsWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: ZahlungsWeb.ErrorHTML, json: ZahlungsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Zahlungs.PubSub,
  live_view: [signing_salt: "R9pDsgA+"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :zahlungs, Zahlungs.Mailer, adapter: Swoosh.Adapters.Local

# Sender of the account emails ({name, address}).
config :zahlungs, :mail_from, {"Zahlungs", "no-reply@example.com"}

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.23.1",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.13",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :zahlungs, :env, Mix.env()

# PPOB providers an account may pick (Zahlungs.Services.Provider). The fake
# one is for trying the flow; prod.exs leaves only real vendors.
config :zahlungs, :provider_adapters, %{
  "sbi" => Zahlungs.Services.Provider.Sbi,
  "fake" => Zahlungs.Services.Provider.Fake
}

# Smart Biller Indonesia (HTTPS JSON API with signed requests).
config :zahlungs, Zahlungs.Services.Provider.Sbi,
  base_url: "https://apisbi.mesinr1.com/V1",
  client: Zahlungs.Services.Provider.Sbi.Client,
  callback_ips: ["183.91.82.154"],
  # SBI's public price list (moved in 2026-10 from api.billerindonesia.com).
  pricelist_url: "https://bo.smartbiller.co.id/v1/public/h2h-umum/json"

# Where the landing page (`/`) tells visitors to reach us. `whatsapp` is the
# number in international form without the plus sign.
config :zahlungs, :contact,
  email: "riszkhy@gmail.com",
  whatsapp: "628978844555"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
