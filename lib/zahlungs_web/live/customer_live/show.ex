defmodule ZahlungsWeb.CustomerLive.Show do
  @moduledoc """
  A customer's ledger (kartu piutang), admin only: credit notes and repayments
  in order with the running balance, which notes each repayment settled, and
  the admin's corrections: cancel a repayment (while its shift is open) and
  hand an overpayment back. The context re-checks the role for both.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Customers, LocalTime}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, socket |> assign(:customer, Customers.get_customer!(id)) |> load()}
  end

  @impl true
  def handle_event("cancel_payment", %{"payment_id" => id, "reason" => reason}, socket) do
    case Customers.cancel_payment(socket.assigns.current_user, id, reason) do
      {:ok, _payment} ->
        {:noreply, socket |> put_flash(:info, "Pelunasan dibatalkan.") |> load()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Isi alasan pembatalan.")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> load()}
    end
  end

  def handle_event("refund_overpayment", %{"amount" => amount}, socket) do
    case Customers.refund_overpayment(
           socket.assigns.current_user,
           socket.assigns.customer.id,
           amount
         ) do
      {:ok, _movement} ->
        {:noreply, socket |> put_flash(:info, "Kelebihan bayar dikembalikan.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp load(socket) do
    customer = socket.assigns.customer
    entries = Customers.ledger(customer)

    assign(socket,
      page_title: customer.name,
      entries: Enum.reverse(entries),
      balance: Customers.balance(customer)
    )
  end

  defp error_message(:unauthorized), do: "Hanya admin yang bisa melakukannya."
  defp error_message(:shift_closed), do: "Shift penerimanya sudah ditutup; angkanya final."
  defp error_message(:already_cancelled), do: "Pelunasan ini sudah dibatalkan."
  defp error_message(:no_open_shift), do: "Buka shift dulu: uangnya keluar dari laci Anda."
  defp error_message(:over_overpayment), do: "Melebihi kelebihan bayar pelanggan."
  defp error_message(_), do: "Tidak bisa diproses."

  defp payment_label("cash"), do: "Tunai"
  defp payment_label("qris"), do: "QRIS"
  defp payment_label("card"), do: "Kartu"
  defp payment_label("transfer"), do: "Transfer"
  defp payment_label(other), do: other

  defp local_time(at, store),
    do: Calendar.strftime(LocalTime.to_local(at, store), "%d/%m/%Y %H:%M")

  defp person(nil), do: "—"
  defp person(%{name: name}) when is_binary(name) and name != "", do: name
  defp person(%{email: email}), do: email

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@customer.name}
      <:subtitle>
        {@customer.phone || "Tanpa no HP"} · Limit {format_money(@customer.credit_limit)}
      </:subtitle>
      <:actions>
        <.link navigate={~p"/admin/customers"} class="btn btn-sm btn-link">Semua pelanggan</.link>
      </:actions>
    </.header>

    <div class="mt-4 rounded-lg border border-gray-200 p-4">
      <p class="text-sm text-gray-500">
        {if Decimal.negative?(@balance), do: "Lebih bayar", else: "Sisa utang"}
      </p>
      <p class={[
        "mt-1 text-2xl font-semibold",
        Decimal.gt?(@balance, 0) && "text-red-700"
      ]}>
        {format_money(Decimal.abs(@balance))}
      </p>

      <form
        :if={Decimal.negative?(@balance)}
        id="refund-overpayment"
        phx-submit="refund_overpayment"
        class="mt-3 flex flex-wrap items-end gap-2"
      >
        <label class="text-sm">
          Kembalikan kelebihan (tunai dari laci Anda)
          <input
            type="number"
            name="amount"
            min="1"
            step="1"
            value={Decimal.to_string(Decimal.abs(@balance), :normal)}
            class="form-control"
          />
        </label>
        <.button data-confirm="Uang keluar dari laci shift Anda. Lanjutkan?">Kembalikan</.button>
      </form>
    </div>

    <h2 class="mt-6 font-semibold">Kartu piutang</h2>
    <p :if={@entries == []} class="mt-2 text-sm text-gray-500">Belum ada nota piutang.</p>

    <ul id="ledger" class="mt-2 divide-y divide-gray-200 rounded-lg border border-gray-200">
      <li :for={entry <- @entries} class="p-3 text-sm">
        <%= case entry.kind do %>
          <% :sale -> %>
            <div class="flex justify-between gap-3">
              <div class={entry.status == :cancelled && "line-through text-gray-400"}>
                <span class="font-medium">Nota {entry.sale.code}</span>
                · {local_time(entry.at, entry.sale.store)} · {entry.sale.store.name} · {person(
                  entry.sale.user
                )}
                <div class="text-xs text-gray-500">
                  Jatuh tempo {entry.sale.due_date && Calendar.strftime(entry.sale.due_date, "%d/%m/%Y")}
                  <span :if={Decimal.gt?(entry.sale.amount_paid, 0)}>
                    · uang muka {format_money(entry.sale.amount_paid)}
                  </span>
                </div>
              </div>
              <div class="text-right">
                <div class={entry.status == :cancelled && "line-through text-gray-400"}>
                  +{format_money(entry.amount)}
                </div>
                <div class="text-xs">
                  <span :if={entry.status == :paid} class="text-green-700">Lunas</span>
                  <span :if={entry.status == :open} class={entry.overdue? && "text-red-700 font-semibold"}>
                    Sisa {format_money(entry.remaining)}{if entry.overdue?, do: " · lewat jatuh tempo"}
                  </span>
                  <span :if={entry.status == :cancelled} class="text-gray-500">Dibatalkan</span>
                </div>
              </div>
            </div>
          <% :payment -> %>
            <div class="flex justify-between gap-3">
              <div class={entry.cancelled? && "line-through text-gray-400"}>
                <span class="font-medium">Pelunasan {payment_label(entry.payment.payment_method)}</span>
                · {local_time(entry.at, entry.payment.store)} · {entry.payment.store.name} · {person(
                  entry.payment.user
                )}
                <div :if={entry.settles != []} class="text-xs text-gray-500">
                  <span :for={s <- entry.settles} class="mr-2">
                    {s.code}: {if Decimal.equal?(s.remaining, 0),
                      do: "lunas",
                      else: "sisa " <> format_money(s.remaining)}
                  </span>
                </div>
              </div>
              <div class={["text-right", entry.cancelled? && "line-through text-gray-400"]}>
                −{format_money(entry.amount)}
              </div>
            </div>
            <p :if={entry.cancelled?} class="mt-1 text-xs text-gray-500">
              Dibatalkan oleh {person(entry.payment.cancelled_by)}: {entry.payment.cancel_reason}
            </p>
            <form
              :if={not entry.cancelled?}
              phx-submit="cancel_payment"
              class="mt-2 flex flex-wrap gap-2"
            >
              <input type="hidden" name="payment_id" value={entry.payment.id} />
              <input
                type="text"
                name="reason"
                maxlength="255"
                placeholder="Alasan pembatalan"
                class="form-control text-xs"
              />
              <button type="submit" class="chip-sm" data-confirm="Batalkan pelunasan ini?">
                Batalkan
              </button>
            </form>
          <% :cancel -> %>
            <div class="flex justify-between gap-3">
              <div>
                <span class="font-medium">
                  Nota {entry.sale.code} {if entry.sale.status == "void", do: "dibatalkan (void)", else: "diretur"}
                </span>
                · {local_time(entry.at, entry.sale.store)}
              </div>
              <div class="text-right">−{format_money(entry.amount)}</div>
            </div>
          <% :refund -> %>
            <div class="flex justify-between gap-3">
              <div>
                <span class="font-medium">Kelebihan dikembalikan</span>
                · {local_time(entry.at, nil)}
              </div>
              <div class="text-right">+{format_money(entry.amount)}</div>
            </div>
        <% end %>
        <div class="mt-1 text-right text-xs text-gray-500">
          Saldo {format_money(entry.balance)}
        </div>
      </li>
    </ul>
    """
  end
end
