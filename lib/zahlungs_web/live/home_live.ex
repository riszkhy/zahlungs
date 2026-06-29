defmodule ZahlungsWeb.HomeLive do
  @moduledoc """
  Home / dashboard: greeting + summary cards and quick navigation.

  Sales-related figures (today's sales, transaction count) arrive in Sprint 3
  once the Sales context exists.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Sales}

  @low_stock_threshold 5

  @impl true
  def mount(_params, _session, socket) do
    summary = Sales.sales_summary_today()
    low_stock_products = Catalog.list_low_stock_products(@low_stock_threshold)

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:active_products, Catalog.count_products(active: true))
     |> assign(:low_stock_products, low_stock_products)
     |> assign(:low_stock, length(low_stock_products))
     |> assign(:categories, length(Catalog.list_categories()))
     |> assign(:sales_today_total, ZahlungsWeb.CoreComponents.format_money(summary.total))
     |> assign(:sales_today_count, summary.count)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Home
      <:subtitle>Halo, {@current_user.email} — selamat datang di Zahlungs POS</:subtitle>
    </.header>

    <div class="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat_card label="Active Products" value={@active_products} accent="text-blue-600" />
      <.stat_card label="Low Stock" value={@low_stock} accent="text-amber-600" />
      <.stat_card label="Categories" value={@categories} accent="text-gray-700" />
      <.stat_card
        label="Sales Today"
        value={@sales_today_total}
        accent="text-green-600"
        hint={"#{@sales_today_count} transaction(s)"}
      />
    </div>

    <div :if={@current_user.role == "admin" and @low_stock_products != []} class="mt-8 rounded-lg border border-amber-200 bg-amber-50 p-4">
      <h3 class="font-semibold text-amber-800">Low stock — needs restock</h3>
      <ul class="mt-2 divide-y divide-amber-100">
        <li :for={product <- @low_stock_products} class="flex justify-between py-1 text-sm">
          <span class="text-gray-700">{product.name} <span class="text-gray-400">({product.sku})</span></span>
          <span class="font-medium text-amber-700">{product.stock} left</span>
        </li>
      </ul>
      <.link navigate={~p"/products"} class="mt-3 inline-block text-sm text-blue-600 hover:underline">
        Manage products →
      </.link>
    </div>

    <h3 class="mt-10 font-semibold text-gray-700">Quick actions</h3>
    <div class="mt-3 flex flex-wrap gap-3">
      <.link navigate={~p"/cashier"}><.button>Open Cashier</.button></.link>
      <.link navigate={~p"/catalog"} class="btn btn-sm btn-link">Browse Catalog</.link>
      <.link navigate={~p"/users/settings"} class="btn btn-sm btn-link">Profile</.link>
      <.link :if={@current_user.role == "admin"} navigate={~p"/products"} class="btn btn-sm btn-link">
        Manage Products
      </.link>
      <.link :if={@current_user.role == "admin"} navigate={~p"/categories"} class="btn btn-sm btn-link">
        Manage Categories
      </.link>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: "text-gray-800"
  attr :hint, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-200 p-5 shadow-sm">
      <p class="text-sm text-gray-500">{@label}</p>
      <p class={["mt-2 text-3xl font-semibold", @accent]}>{@value}</p>
      <p :if={@hint} class="mt-1 text-xs text-gray-400">{@hint}</p>
    </div>
    """
  end
end
