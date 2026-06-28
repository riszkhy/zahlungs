defmodule ZahlungsWeb.HomeLive do
  @moduledoc """
  Home / dashboard. Placeholder skeleton — the summary cards are implemented in
  Sprint 2 (see docs/SPRINT-PLAN.md).
  """
  use ZahlungsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Home")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Home
      <:subtitle>Selamat datang di Zahlungs POS</:subtitle>
    </.header>

    <p class="mt-6 text-gray-600 dark:text-gray-300">
      Dashboard ringkasan (penjualan hari ini, jumlah transaksi, produk aktif,
      stok menipis) akan hadir di <strong>Sprint 2</strong>.
    </p>
    """
  end
end
