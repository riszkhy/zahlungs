defmodule Zahlungs.Services.Dispatcher do
  @moduledoc """
  Sends an api service to the provider after it is committed — in a supervised
  background task, not in the cashier's LiveView, so closing the screen doesn't
  lose the payment. Tests run it inline (`config :zahlungs, :service_dispatch,
  :inline`), in the test's own process and database sandbox.

  If the task never runs (the server stops first), the status checker finds the
  service unsent and sends it (see `Zahlungs.Services.check_pending/1`).
  """

  alias Zahlungs.Services

  @doc "Starts sending `transaction` to its provider."
  def dispatch(%Services.Transaction{id: id}) do
    case Application.get_env(:zahlungs, :service_dispatch, :async) do
      :inline ->
        Services.send_payment(id)

      :async ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Zahlungs.Services.TaskSupervisor, fn ->
            Services.send_payment(id)
          end)

        :ok
    end
  end
end
