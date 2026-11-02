defmodule ZahlungsWeb.ServiceCommissionLive do
  @moduledoc """
  Admin page for the cashier commission: per service category, a percent of
  the margin or a rupiah amount per service, one table for the whole
  organization. A service carries the rule of the moment it is recorded, so a
  change here only reaches the services recorded after it.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Services

  @impl true
  def mount(_params, _session, socket) do
    rates = Services.commission_rates()

    {:ok,
     assign(socket, page_title: "Komisi kasir", rates: rates, values: values(rates), errors: %{})}
  end

  @impl true
  def handle_event("save", %{"rates" => values}, socket) do
    case Services.save_commission_rates(socket.assigns.current_user, values) do
      {:ok, rates} ->
        {:noreply,
         socket
         |> assign(rates: rates, values: values(rates), errors: %{})
         |> put_flash(:info, "Komisi disimpan.")}

      {:error, errors} when is_map(errors) ->
        {:noreply,
         assign(socket, values: Map.merge(socket.assigns.values, values), errors: errors)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Hanya admin yang bisa mengubah komisi.")}
    end
  end

  # What the form shows for each category: its kind and that kind's value.
  defp values(rates) do
    Map.new(rates, fn rate ->
      {rate.category, %{"kind" => rate.kind, "value" => value(rate)}}
    end)
  end

  defp value(%{kind: "amount", amount: amount}),
    do: amount |> Decimal.round(0) |> Decimal.to_string(:normal)

  defp value(%{percent: percent}),
    do: percent |> Decimal.normalize() |> Decimal.to_string(:normal)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Komisi kasir
      <:subtitle>Komisi transaksi layanan yang sukses, per kategori (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/services"} class="chip">Produk layanan</.link>
      </:actions>
    </.header>

    <div class="mt-4 max-w-2xl space-y-1 text-sm text-gray-600">
      <p>
        <strong>Persen:</strong>
        persen × margin (harga − modal) tiap transaksi sukses yang dicatat kasir.
      </p>
      <p>
        <strong>Rupiah:</strong>
        nominal tetap per transaksi sukses, tagihan beberapa bulan tetap satu kali. Komisi ini
        tetap dibayar penuh walau margin transaksinya lebih kecil.
      </p>
      <p>Perubahan berlaku untuk transaksi berikutnya.</p>
    </div>

    <form id="commission-form" phx-submit="save" class="mt-6 max-w-md space-y-3">
      <div :for={rate <- @rates}>
        <div class="flex items-center justify-between gap-4 text-sm">
          <span class="font-medium">{rate.label}</span>
          <span class="flex items-center gap-2">
            <select name={"rates[#{rate.category}][kind]"} class="form-control w-28" aria-label={"Jenis komisi #{rate.label}"}>
              <option value="percent" selected={@values[rate.category]["kind"] != "amount"}>Persen</option>
              <option value="amount" selected={@values[rate.category]["kind"] == "amount"}>Rupiah</option>
            </select>
            <input
              type="text"
              inputmode="decimal"
              name={"rates[#{rate.category}][value]"}
              value={@values[rate.category]["value"]}
              class="form-control w-28 text-right"
              autocomplete="off"
              aria-label={"Nilai komisi #{rate.label}"}
            />
          </span>
        </div>
        <p :if={@errors[rate.category]} class="mt-1 text-right text-xs text-red-600">
          {@errors[rate.category]}
        </p>
      </div>

      <div class="pt-3"><.button class="w-full">Simpan</.button></div>
    </form>
    """
  end
end
