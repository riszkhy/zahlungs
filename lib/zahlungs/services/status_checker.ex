defmodule Zahlungs.Services.StatusChecker do
  @moduledoc """
  Every minute, settles PPOB services still pending at the provider
  (`Zahlungs.Services.check_pending/1`): asks about those sent, and sends
  those a crash left unsent. The first round runs shortly after boot, so
  services left behind by a restart are picked up.

  Off in tests (`config :zahlungs, :service_status_checker, false`).
  """
  use GenServer

  require Logger

  @interval :timer.seconds(60)
  @first_round :timer.seconds(5)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_round)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      Zahlungs.Services.check_pending()
    rescue
      error -> Logger.error("PPOB status check failed: " <> Exception.message(error))
    end

    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end
end
