defmodule ZahlungsWeb.ReportLive.Stock do
  @moduledoc """
  Stock / inventory report (admin only): a snapshot of current stock value and
  low/out-of-stock products. Not date-ranged — reflects the catalog right now.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Catalog

  @threshold 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Stock Report")
     |> assign(:threshold, @threshold)
     |> assign(:report, Catalog.stock_report(@threshold))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Stock Report
      <:subtitle>Snapshot persediaan saat ini (khusus admin)</:subtitle>
    </.header>

    <div class="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat label="Active products" value={@report.products} accent="text-blue-600" />
      <.stat label="Units in stock" value={@report.units} accent="text-gray-700" />
      <.stat label="Stock value (cost)" value={format_money(@report.cost_value)} accent="text-amber-600" />
      <.stat
        label="Stock value (retail)"
        value={format_money(@report.retail_value)}
        accent="text-green-600"
      />
    </div>

    <p class="mt-3 text-sm text-gray-500">
      Potential profit if all stock sells: <strong>{format_money(@report.potential_profit)}</strong>
    </p>

    <h3 class="mt-10 font-semibold text-amber-700">Low stock (≤ {@threshold})</h3>
    <.table id="low-stock" rows={@report.low_stock}>
      <:col :let={p} label="Product">{p.name}</:col>
      <:col :let={p} label="SKU">{p.sku}</:col>
      <:col :let={p} label="Category">{p.category && p.category.name}</:col>
      <:col :let={p} label="Stock">{p.stock}</:col>
    </.table>

    <h3 class="mt-10 font-semibold text-red-700">Out of stock</h3>
    <.table id="out-of-stock" rows={@report.out_of_stock}>
      <:col :let={p} label="Product">{p.name}</:col>
      <:col :let={p} label="SKU">{p.sku}</:col>
      <:col :let={p} label="Category">{p.category && p.category.name}</:col>
    </.table>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: "text-gray-800"

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-200 p-5 shadow-sm">
      <p class="text-sm text-gray-500">{@label}</p>
      <p class={["mt-2 text-2xl font-semibold", @accent]}>{@value}</p>
    </div>
    """
  end
end
