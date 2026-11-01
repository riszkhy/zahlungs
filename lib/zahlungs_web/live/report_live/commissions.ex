defmodule ZahlungsWeb.ReportLive.Commissions do
  @moduledoc """
  Cashier commission report (admin only): per cashier, the successful
  services of a date range that earned a commission, their margin and the
  commission; a cashier's name opens the services behind it. Paid outside
  Zahlungs; this is the figure to pay.
  """
  use ZahlungsWeb, :live_view

  import ZahlungsWeb.CommissionComponents

  alias Zahlungs.Services

  @impl true
  def mount(_params, _session, socket) do
    today = Zahlungs.LocalTime.today(socket.assigns.current_scope.store)

    {:ok,
     socket
     |> assign(:page_title, "Komisi kasir")
     |> assign(from: Date.to_iso8601(Date.beginning_of_month(today)), to: Date.to_iso8601(today))
     |> assign(selected: nil)
     |> load_report()}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: from, to: to) |> load_report()}
  end

  # The id arrives as a JSON number from JS.push; a string works too.
  def handle_event("select_cashier", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected, to_int(id)) |> load_report()}
  end

  defp load_report(socket) do
    scope = socket.assigns.current_scope

    case parse_range(socket.assigns.from, socket.assigns.to) do
      {:ok, from, to} ->
        selected = socket.assigns.selected

        assign(socket,
          report: Services.commission_report(scope, from, to),
          details:
            if(selected, do: Services.commission_details(scope, selected, from, to), else: [])
        )

      :error ->
        assign(socket, report: nil, details: [])
    end
  end

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp selected_name(report, selected) do
    Enum.find_value(report.rows, fn row -> if row.user_id == selected, do: row.name end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Komisi kasir
      <:subtitle>Komisi transaksi layanan yang sukses, per kasir (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/services/commission"} class="chip">Atur persen</.link>
      </:actions>
    </.header>

    <.date_filter from={@from} to={@to} />

    <p :if={is_nil(@report)} class="mt-6 text-sm text-gray-500">Pilih rentang tanggal yang valid.</p>

    <div :if={@report}>
      <p :if={@report.rows == []} class="mt-6 text-sm text-gray-500">Belum ada komisi pada periode ini.</p>

      <.table :if={@report.rows != []} id="commissions-by-cashier" rows={@report.rows}>
        <:col :let={row} label="Kasir">
          <.link phx-click={JS.push("select_cashier", value: %{id: row.user_id})} class="font-medium underline">
            {row.name}
          </.link>
        </:col>
        <:col :let={row} label="Transaksi">{row.count}</:col>
        <:col :let={row} label="Margin">{format_money(row.margin)}</:col>
        <:col :let={row} label="Komisi">{format_money(row.commission)}</:col>
      </.table>

      <p :if={@report.rows != []} class="mt-3 text-right text-sm">
        Total {@report.count} transaksi · margin {format_money(@report.margin)} ·
        <strong>komisi {format_money(@report.commission)}</strong>
      </p>

      <section :if={@selected && @details != []} class="mt-8">
        <h3 class="font-semibold">Rincian {selected_name(@report, @selected)}</h3>
        <.details_table id="commission-details" details={@details} store={@current_scope.store} />
      </section>
    </div>
    """
  end
end
