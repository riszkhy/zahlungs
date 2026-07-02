defmodule ZahlungsWeb.ReportLive.Consignment do
  @moduledoc """
  Consignment settlement report (admin only): per-supplier amount payable for
  consignment products sold in the date range (Model A — fixed supplier price,
  taken from each sale item's purchase-price snapshot), plus the on-hand
  consignment stock still returnable to each supplier.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Sales, Shifts}

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()
    from = Date.beginning_of_month(today)

    {:ok,
     socket
     |> assign(:page_title, "Consignment Settlement")
     |> assign(from: Date.to_iso8601(from), to: Date.to_iso8601(today))
     |> assign(:on_hand, Catalog.consignment_stock_on_hand())
     |> load_report()}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: from, to: to) |> load_report()}
  end

  defp load_report(socket) do
    with {:ok, from} <- Date.from_iso8601(socket.assigns.from),
         {:ok, to} <- Date.from_iso8601(socket.assigns.to) do
      paid = Shifts.consignment_payments_by_supplier(from, to)

      rows =
        from
        |> Sales.consignment_settlement(to)
        |> Enum.map(fn r ->
          paid_amount = Map.get(paid, r.supplier_id, Decimal.new(0))
          Map.merge(r, %{paid: paid_amount, outstanding: Decimal.sub(r.payable, paid_amount)})
        end)

      assign(socket, settlement: rows, totals: totals(rows))
    else
      _ -> assign(socket, settlement: [], totals: zero_totals())
    end
  end

  defp totals(rows) do
    Enum.reduce(rows, zero_totals(), fn r, acc ->
      %{
        qty_sold: acc.qty_sold + r.qty_sold,
        revenue: Decimal.add(acc.revenue, r.revenue),
        payable: Decimal.add(acc.payable, r.payable),
        margin: Decimal.add(acc.margin, r.margin),
        paid: Decimal.add(acc.paid, r.paid),
        outstanding: Decimal.add(acc.outstanding, r.outstanding)
      }
    end)
  end

  defp zero_totals do
    %{
      qty_sold: 0,
      revenue: Decimal.new(0),
      payable: Decimal.new(0),
      margin: Decimal.new(0),
      paid: Decimal.new(0),
      outstanding: Decimal.new(0)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Consignment Settlement
      <:subtitle>Yang harus dibayar ke supplier titipan (khusus admin)</:subtitle>
      <:actions>
        <.link :if={@current_user.role == "admin"} patch={~p"/admin/suppliers"} class="btn btn-sm btn-link">
          Suppliers
        </.link>
      </:actions>
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

    <div class="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat label="Omzet titipan" value={format_money(@totals.revenue)} accent="text-green-600" />
      <.stat label="Harus dibayar ke supplier" value={format_money(@totals.payable)} accent="text-gray-700" />
      <.stat label="Sudah dibayar" value={format_money(@totals.paid)} accent="text-blue-600" />
      <.stat label="Sisa (outstanding)" value={format_money(@totals.outstanding)} accent="text-red-600" />
    </div>

    <p class="mt-3 text-sm text-gray-500">Margin toko: <strong>{format_money(@totals.margin)}</strong></p>

    <h3 class="mt-10 font-semibold text-gray-700">Per supplier (terjual pada rentang tanggal)</h3>
    <.table id="settlement" rows={@settlement}>
      <:col :let={r} label="Supplier">{r.supplier}</:col>
      <:col :let={r} label="Qty terjual">{r.qty_sold}</:col>
      <:col :let={r} label="Omzet">{format_money(r.revenue)}</:col>
      <:col :let={r} label="Harus dibayar">{format_money(r.payable)}</:col>
      <:col :let={r} label="Sudah dibayar">{format_money(r.paid)}</:col>
      <:col :let={r} label="Sisa">
        <span class={if Decimal.gt?(r.outstanding, Decimal.new(0)), do: "text-red-600", else: "text-green-600"}>
          {format_money(r.outstanding)}
        </span>
      </:col>
    </.table>
    <p :if={@settlement == []} class="mt-2 text-sm text-gray-500">
      Belum ada penjualan barang titipan pada rentang ini.
    </p>

    <h3 class="mt-10 font-semibold text-amber-700">Sisa stok titipan (bisa dikembalikan)</h3>
    <.table id="on-hand" rows={@on_hand}>
      <:col :let={r} label="Supplier">{r.supplier}</:col>
      <:col :let={r} label="Jenis produk">{r.products}</:col>
      <:col :let={r} label="Unit">{r.units}</:col>
      <:col :let={r} label="Nilai (harga titip)">{format_money(r.cost_value)}</:col>
    </.table>
    <p :if={@on_hand == []} class="mt-2 text-sm text-gray-500">
      Tidak ada sisa stok titipan.
    </p>
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
