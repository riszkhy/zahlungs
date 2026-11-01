defmodule ZahlungsWeb.CommissionLive do
  @moduledoc """
  A cashier's own commission ("Komisi saya"): the total of a date range and
  the services behind it. Only ever the signed-in cashier's (the context
  limits a cashier's scope to themself); an admin, who earns none, is sent to
  the report of every cashier.
  """
  use ZahlungsWeb, :live_view

  import ZahlungsWeb.CommissionComponents

  alias Zahlungs.Services

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role == "admin" do
      {:ok, push_navigate(socket, to: ~p"/reports/commissions")}
    else
      today = Zahlungs.LocalTime.today(socket.assigns.current_scope.store)

      {:ok,
       socket
       |> assign(:page_title, "Komisi saya")
       |> assign(
         from: Date.to_iso8601(Date.beginning_of_month(today)),
         to: Date.to_iso8601(today)
       )
       |> load_report()}
    end
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    {:noreply, socket |> assign(from: from, to: to) |> load_report()}
  end

  defp load_report(socket) do
    scope = socket.assigns.current_scope

    case parse_range(socket.assigns.from, socket.assigns.to) do
      {:ok, from, to} ->
        assign(socket,
          report: Services.commission_report(scope, from, to),
          details: Services.commission_details(scope, scope.user.id, from, to)
        )

      :error ->
        assign(socket, report: nil, details: [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Komisi saya
      <:subtitle>Komisi dari transaksi layanan sukses yang Anda catat</:subtitle>
    </.header>

    <.date_filter from={@from} to={@to} />

    <p :if={is_nil(@report)} class="mt-6 text-sm text-gray-500">Pilih rentang tanggal yang valid.</p>

    <div :if={@report}>
      <div class="mt-6 grid grid-cols-3 gap-4">
        <div class="rounded-lg border border-gray-200 p-4">
          <p class="text-sm text-gray-500">Transaksi</p>
          <p class="mt-1 text-2xl font-semibold">{@report.count}</p>
        </div>
        <div class="rounded-lg border border-gray-200 p-4">
          <p class="text-sm text-gray-500">Margin</p>
          <p class="mt-1 text-xl font-semibold">{format_money(@report.margin)}</p>
        </div>
        <div class="rounded-lg border border-gray-200 p-4">
          <p class="text-sm text-gray-500">Komisi</p>
          <p class="mt-1 text-xl font-semibold text-green-700">{format_money(@report.commission)}</p>
        </div>
      </div>

      <p :if={@details == []} class="mt-6 text-sm text-gray-500">Belum ada komisi pada periode ini.</p>
      <.details_table :if={@details != []} id="my-commission" details={@details} store={@current_scope.store} />
    </div>
    """
  end
end
