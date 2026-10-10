defmodule Zahlungs.Accounts.LoginPruner do
  @moduledoc """
  Deletes login-log rows older than the retention period, once at boot and then
  daily. Login locations are personal data and are not kept forever
  (`config :zahlungs, :login_log_retention_days`, default 90).
  """
  use GenServer

  require Logger

  @interval :timer.hours(24)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :prune)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    days = Application.get_env(:zahlungs, :login_log_retention_days, 90)

    try do
      Zahlungs.Accounts.prune_user_logins(days)
    rescue
      # The table may not exist yet (first boot before migrating); try again tomorrow.
      error -> Logger.warning("Could not prune the login log: #{Exception.message(error)}")
    end

    Process.send_after(self(), :prune, @interval)
    {:noreply, state}
  end
end
