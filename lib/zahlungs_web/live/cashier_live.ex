defmodule ZahlungsWeb.CashierLive do
  @moduledoc """
  Cashier / point-of-sale screen. Placeholder skeleton — the cart and transaction
  flow are implemented in Sprint 3 (see docs/SPRINT-PLAN.md).
  """
  use ZahlungsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Cashier")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Cashier
      <:subtitle>Layar transaksi penjualan</:subtitle>
    </.header>

    <p class="mt-6 text-gray-600 dark:text-gray-300">
      Keranjang, perhitungan total, dan penyelesaian transaksi akan hadir di
      <strong>Sprint 3</strong>.
    </p>
    """
  end
end
