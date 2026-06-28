defmodule ZahlungsWeb.SalesLive.Index do
  @moduledoc """
  Sales / transaction history: list recent sales with an optional date filter and
  a detail modal. Available to any authenticated user.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Sales

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:date, "")
     |> load_sales()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sales")
    |> assign(:sale, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(:page_title, "Sale detail")
    |> assign(:sale, Sales.get_sale!(id))
  end

  @impl true
  def handle_event("filter", %{"date" => date}, socket) do
    {:noreply, socket |> assign(:date, date) |> load_sales()}
  end

  defp load_sales(socket) do
    assign(socket, :sales, Sales.list_sales(date: parse_date(socket.assigns.date)))
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp money(%Decimal{} = d), do: "Rp " <> Decimal.to_string(d)
  defp money(other), do: "Rp #{other}"

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Sales
      <:subtitle>Riwayat transaksi</:subtitle>
    </.header>

    <form phx-change="filter" class="mt-6 flex items-end gap-3">
      <label class="text-sm">
        Filter by date
        <input type="date" name="date" value={@date} class="form-control" />
      </label>
    </form>

    <.table id="sales" rows={@sales}>
      <:col :let={sale} label="Code">{sale.code}</:col>
      <:col :let={sale} label="Date">{Calendar.strftime(sale.inserted_at, "%d %b %Y %H:%M")}</:col>
      <:col :let={sale} label="Cashier">{sale.user && sale.user.email}</:col>
      <:col :let={sale} label="Items">{length(sale.items)}</:col>
      <:col :let={sale} label="Total">{money(sale.total)}</:col>
      <:action :let={sale}>
        <.link patch={~p"/sales/#{sale}"}>View</.link>
      </:action>
    </.table>

    <.modal :if={@live_action == :show and @sale} id="sale-modal" show on_cancel={JS.patch(~p"/sales")}>
      <h3 class="text-lg font-semibold">Sale {@sale.code}</h3>
      <p class="text-xs text-gray-400">
        {Calendar.strftime(@sale.inserted_at, "%d %b %Y %H:%M")} · {@sale.user && @sale.user.email}
      </p>

      <table class="w-full mt-4 text-sm">
        <thead class="text-left text-gray-500">
          <tr>
            <th class="py-1">Item</th>
            <th class="py-1 text-center">Qty</th>
            <th class="py-1 text-right">Unit</th>
            <th class="py-1 text-right">Line</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @sale.items} class="border-t border-gray-100">
            <td class="py-1">{(item.product && item.product.name) || "(deleted)"}</td>
            <td class="py-1 text-center">{item.quantity}</td>
            <td class="py-1 text-right">{money(item.unit_price)}</td>
            <td class="py-1 text-right">{money(item.line_total)}</td>
          </tr>
        </tbody>
      </table>

      <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
        <div class="flex justify-between"><dt>Subtotal</dt><dd>{money(@sale.subtotal)}</dd></div>
        <div class="flex justify-between"><dt>Discount</dt><dd>{money(@sale.discount)}</dd></div>
        <div class="flex justify-between"><dt>Tax</dt><dd>{money(@sale.tax)}</dd></div>
        <div class="flex justify-between font-semibold"><dt>Total</dt><dd>{money(@sale.total)}</dd></div>
        <div class="flex justify-between"><dt>Paid</dt><dd>{money(@sale.amount_paid)}</dd></div>
        <div class="flex justify-between"><dt>Change</dt><dd>{money(@sale.change_due)}</dd></div>
      </dl>
    </.modal>
    """
  end
end
