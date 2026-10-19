defmodule ZahlungsWeb.ReportLive.Services do
  @moduledoc """
  Service report (admin only): the PPOB services of a date range — how many
  succeeded and failed, their value, cost and margin, per category. Goods are
  in the sales report; services are kept apart because a bill's value is
  mostly passed on to the provider.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Services

  @impl true
  def mount(_params, _session, socket) do
    today = Zahlungs.LocalTime.today(socket.assigns.current_scope.store)

    {:ok,
     socket
     |> assign(:page_title, "Laporan layanan")
     |> assign(from: Date.to_iso8601(Date.beginning_of_month(today)), to: Date.to_iso8601(today))
     |> load_report()}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: from, to: to) |> load_report()}
  end

  defp load_report(socket) do
    with {:ok, from} <- Date.from_iso8601(socket.assigns.from),
         {:ok, to} <- Date.from_iso8601(socket.assigns.to) do
      assign(socket, :report, Services.report(socket.assigns.current_scope, from, to))
    else
      _ -> assign(socket, :report, nil)
    end
  end

  defp category_label(category) do
    Enum.find_value(Services.categories(), category, fn {value, label} ->
      if value == category, do: label
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Laporan layanan
      <:subtitle>Pulsa, paket data, token dan tagihan PLN yang berhasil (khusus admin)</:subtitle>
    </.header>

    <form phx-change="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm">Dari <input type="date" name="from" value={@from} class="form-control" /></label>
      <label class="text-sm">Sampai <input type="date" name="to" value={@to} class="form-control" /></label>
    </form>

    <p :if={is_nil(@report)} class="mt-6 text-sm text-gray-500">Pilih rentang tanggal yang valid.</p>

    <div :if={@report} class="mt-6 grid grid-cols-2 gap-4 lg:grid-cols-5">
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Berhasil</p>
        <p class="mt-1 text-2xl font-semibold">{@report.success_count}</p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Gagal</p>
        <p class="mt-1 text-2xl font-semibold">{@report.failed_count}</p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Nilai transaksi</p>
        <p class="mt-1 text-xl font-semibold">{format_money(@report.value)}</p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Modal</p>
        <p class="mt-1 text-xl font-semibold">{format_money(@report.cost)}</p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Margin</p>
        <p class="mt-1 text-xl font-semibold text-green-700">{format_money(@report.margin)}</p>
      </div>
    </div>

    <div :if={@report}>
      <.table id="services-by-category" rows={@report.by_category}>
        <:col :let={row} label="Kategori">{category_label(row.category)}</:col>
        <:col :let={row} label="Berhasil">{row.count}</:col>
        <:col :let={row} label="Nilai">{format_money(row.value)}</:col>
        <:col :let={row} label="Modal">{format_money(row.cost)}</:col>
        <:col :let={row} label="Margin">{format_money(row.margin)}</:col>
      </.table>
    </div>
    """
  end
end
