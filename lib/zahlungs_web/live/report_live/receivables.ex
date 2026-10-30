defmodule ZahlungsWeb.ReportLive.Receivables do
  @moduledoc """
  Receivables report (laporan piutang), admin only: who owes how much across
  the organization, what is past its due date, and the repayments received in
  a date range per payment method and per store.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Customers, LocalTime}

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today(socket.assigns.current_scope.store)

    {:ok,
     socket
     |> assign(:page_title, "Laporan piutang")
     |> assign(
       overdue_only: false,
       from: Date.to_iso8601(Date.beginning_of_month(today)),
       to: Date.to_iso8601(today)
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(
       overdue_only: params["overdue"] == "true",
       from: params["from"] || socket.assigns.from,
       to: params["to"] || socket.assigns.to
     )
     |> load()}
  end

  defp load(socket) do
    report = Customers.receivables_report(overdue_only: socket.assigns.overdue_only)

    payments =
      with {:ok, from} <- Date.from_iso8601(socket.assigns.from),
           {:ok, to} <- Date.from_iso8601(socket.assigns.to) do
        Customers.payments_report(socket.assigns.current_scope, from, to)
      else
        _ -> nil
      end

    assign(socket, report: report, payments: payments)
  end

  defp payment_label("cash"), do: "Tunai"
  defp payment_label("qris"), do: "QRIS"
  defp payment_label("card"), do: "Kartu"
  defp payment_label("transfer"), do: "Transfer"
  defp payment_label(other), do: other

  defp date(nil), do: "—"
  defp date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp date(%NaiveDateTime{} = at),
    do: Calendar.strftime(LocalTime.to_local(at, nil), "%d/%m/%Y")

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Laporan piutang
      <:subtitle>Utang pelanggan di semua toko, dan pelunasan yang diterima (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/customers"} class="btn btn-sm btn-link">Pelanggan</.link>
      </:actions>
    </.header>

    <form phx-change="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm flex items-center gap-2">
        <input type="hidden" name="overdue" value="false" />
        <input type="checkbox" name="overdue" value="true" checked={@overdue_only} />
        Lewat jatuh tempo saja
      </label>
      <label class="text-sm">Pelunasan dari <input type="date" name="from" value={@from} class="form-control" /></label>
      <label class="text-sm">Sampai <input type="date" name="to" value={@to} class="form-control" /></label>
    </form>

    <div class="mt-6 rounded-lg border border-gray-200 p-4">
      <p class="text-sm text-gray-500">Total piutang</p>
      <p class="mt-1 text-2xl font-semibold text-red-700">{format_money(@report.total)}</p>
    </div>

    <p :if={@report.rows == []} class="mt-4 text-sm text-gray-500">Tidak ada pelanggan yang berutang.</p>

    <.table :if={@report.rows != []} id="receivables" rows={@report.rows}>
      <:col :let={row} label="Pelanggan">
        <.link navigate={~p"/admin/customers/#{row.customer.id}"} class="text-green-700 hover:underline">
          {row.customer.name}
        </.link>
      </:col>
      <:col :let={row} label="Utang">{format_money(row.balance)}</:col>
      <:col :let={row} label="Lewat jatuh tempo">
        <span class={Decimal.gt?(row.overdue, 0) && "font-semibold text-red-700"}>
          {format_money(row.overdue)}
        </span>
      </:col>
      <:col :let={row} label="Nota terlama">
        {row.oldest_open && "#{row.oldest_open.code} · jatuh tempo #{date(row.oldest_open.due_date)}"}
      </:col>
      <:col :let={row} label="Pelunasan terakhir">{date(row.last_payment_at)}</:col>
    </.table>

    <h2 class="mt-8 font-semibold">Pelunasan diterima</h2>
    <p :if={is_nil(@payments)} class="mt-2 text-sm text-gray-500">Pilih rentang tanggal yang valid.</p>

    <div :if={@payments} class="mt-2 grid gap-4 md:grid-cols-3">
      <div class="rounded-lg border border-gray-200 p-4">
        <p class="text-sm text-gray-500">Total</p>
        <p class="mt-1 text-xl font-semibold">{format_money(@payments.total)}</p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4 text-sm">
        <p class="text-gray-500">Per cara bayar</p>
        <p :for={{method, amount} <- @payments.by_method} class="mt-1 flex justify-between">
          <span>{payment_label(method)}</span><span>{format_money(amount)}</span>
        </p>
      </div>
      <div class="rounded-lg border border-gray-200 p-4 text-sm">
        <p class="text-gray-500">Per toko</p>
        <p :for={{name, amount} <- @payments.by_store} class="mt-1 flex justify-between">
          <span>{name}</span><span>{format_money(amount)}</span>
        </p>
      </div>
    </div>
    """
  end
end
