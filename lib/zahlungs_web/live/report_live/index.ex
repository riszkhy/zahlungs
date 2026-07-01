defmodule ZahlungsWeb.ReportLive.Index do
  @moduledoc """
  Sales report (admin only): date-range summary + top products. Profit uses the
  purchase-price snapshot stored on each sale item.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Sales

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()
    from = Date.beginning_of_month(today)

    {:ok,
     socket
     |> assign(:page_title, "Sales Report")
     |> assign(from: Date.to_iso8601(from), to: Date.to_iso8601(today))
     |> load_report()}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: from, to: to) |> load_report()}
  end

  defp load_report(socket) do
    with {:ok, from} <- Date.from_iso8601(socket.assigns.from),
         {:ok, to} <- Date.from_iso8601(socket.assigns.to) do
      socket
      |> assign(:report, Sales.sales_report(from, to))
      |> assign(:top_products, Sales.top_products(from, to))
      |> assign(:by_day, Sales.sales_by_day(from, to))
      |> assign(:by_cashier, Sales.sales_by_cashier(from, to))
      |> assign(:by_category, Sales.sales_by_category(from, to))
    else
      _ ->
        assign(socket, report: nil, top_products: [], by_day: [], by_cashier: [], by_category: [])
    end
  end

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  defp format_date(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Sales Report
      <:subtitle>Ringkasan penjualan & laba (khusus admin)</:subtitle>
    </.header>

    <form phx-change="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm">
        From
        <input type="date" name="from" value={@from} class="form-control" />
      </label>
      <label class="text-sm">
        To
        <input type="date" name="to" value={@to} class="form-control" />
      </label>
    </form>

    <div :if={@report} class="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat label="Revenue (net)" value={format_money(@report.revenue)} accent="text-green-600" />
      <.stat label="Transactions" value={@report.transactions} accent="text-blue-600" />
      <.stat label="Items sold" value={@report.items_sold} accent="text-gray-700" />
      <.stat label="Gross profit" value={format_money(@report.gross_profit)} accent="text-emerald-600" />
    </div>

    <div :if={@report} class="mt-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat label="Gross sales" value={format_money(@report.gross_sales)} />
      <.stat label="COGS (modal)" value={format_money(@report.cogs)} />
      <.stat label="Discount" value={format_money(@report.discount)} />
      <.stat label="Tax" value={format_money(@report.tax)} />
    </div>

    <h3 class="mt-10 font-semibold text-gray-700">Daily sales</h3>
    <.table id="by-day" rows={@by_day}>
      <:col :let={row} label="Date">{format_date(row.date)}</:col>
      <:col :let={row} label="Transactions">{row.transactions}</:col>
      <:col :let={row} label="Revenue">{format_money(row.revenue)}</:col>
    </.table>

    <h3 class="mt-10 font-semibold text-gray-700">Sales by cashier</h3>
    <.table id="by-cashier" rows={@by_cashier}>
      <:col :let={row} label="Cashier">{row.cashier || "(unknown)"}</:col>
      <:col :let={row} label="Transactions">{row.transactions}</:col>
      <:col :let={row} label="Revenue">{format_money(row.revenue)}</:col>
    </.table>

    <h3 class="mt-10 font-semibold text-gray-700">Sales by category</h3>
    <.table id="by-category" rows={@by_category}>
      <:col :let={row} label="Category">{row.category || "Uncategorized"}</:col>
      <:col :let={row} label="Qty sold">{row.quantity}</:col>
      <:col :let={row} label="Revenue">{format_money(row.revenue)}</:col>
    </.table>

    <h3 class="mt-10 font-semibold text-gray-700">Top products</h3>
    <.table id="top-products" rows={@top_products}>
      <:col :let={row} label="Product">{row.name || "(deleted)"}</:col>
      <:col :let={row} label="Qty sold">{row.quantity}</:col>
      <:col :let={row} label="Revenue">{format_money(row.revenue)}</:col>
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
