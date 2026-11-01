defmodule ZahlungsWeb.ServiceCommissionLive do
  @moduledoc """
  Admin page for the cashier commission: a percent of the margin per service
  category, one table for the whole organization. A service carries the
  percent of the moment it is recorded, so a change here only reaches the
  services recorded after it.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Services

  @impl true
  def mount(_params, _session, socket) do
    rates = Services.commission_rates()

    {:ok,
     assign(socket,
       page_title: "Komisi kasir",
       rates: rates,
       values: Map.new(rates, &{&1.category, Decimal.to_string(&1.percent, :normal)}),
       errors: %{}
     )}
  end

  @impl true
  def handle_event("save", %{"rates" => values}, socket) do
    case Services.save_commission_rates(socket.assigns.current_user, values) do
      {:ok, rates} ->
        {:noreply,
         socket
         |> assign(
           rates: rates,
           values: Map.new(rates, &{&1.category, Decimal.to_string(&1.percent, :normal)}),
           errors: %{}
         )
         |> put_flash(:info, "Persen komisi disimpan.")}

      {:error, errors} when is_map(errors) ->
        {:noreply,
         assign(socket, values: Map.merge(socket.assigns.values, values), errors: errors)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Hanya admin yang bisa mengubah komisi.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Komisi kasir
      <:subtitle>Persen dari margin transaksi layanan yang sukses (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/services"} class="chip">Produk layanan</.link>
      </:actions>
    </.header>

    <p class="mt-4 max-w-2xl text-sm text-gray-600">
      Komisi = persen × margin (harga − modal) transaksi sukses yang dicatat kasir.
      Perubahan berlaku untuk transaksi berikutnya.
    </p>

    <form id="commission-form" phx-submit="save" class="mt-6 max-w-md space-y-3">
      <div :for={rate <- @rates}>
        <label class="flex items-center justify-between gap-4 text-sm">
          <span class="font-medium">{rate.label}</span>
          <span class="flex items-center gap-1">
            <input
              type="number"
              name={"rates[#{rate.category}]"}
              value={@values[rate.category]}
              step="0.01"
              min="0"
              max="100"
              class="form-control w-28 text-right"
            /> %
          </span>
        </label>
        <p :if={@errors[rate.category]} class="mt-1 text-right text-xs text-red-600">
          {@errors[rate.category]}
        </p>
      </div>

      <div class="pt-3"><.button class="w-full">Simpan</.button></div>
    </form>
    """
  end
end
