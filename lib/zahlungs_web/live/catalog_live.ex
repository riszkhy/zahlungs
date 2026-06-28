defmodule ZahlungsWeb.CatalogLive do
  @moduledoc """
  Product catalog (read-only browse + search). Placeholder skeleton — implemented
  in Sprint 2 (see docs/SPRINT-PLAN.md).
  """
  use ZahlungsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Catalog")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Catalog Product
      <:subtitle>Telusuri produk yang tersedia</:subtitle>
    </.header>

    <p class="mt-6 text-gray-600 dark:text-gray-300">
      Daftar produk dengan pencarian & filter akan hadir di <strong>Sprint 2</strong>.
    </p>
    """
  end
end
