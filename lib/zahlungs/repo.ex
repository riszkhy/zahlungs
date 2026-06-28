defmodule Zahlungs.Repo do
  use Ecto.Repo,
    otp_app: :zahlungs,
    adapter: Ecto.Adapters.MyXQL
end
