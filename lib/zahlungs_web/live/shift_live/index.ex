defmodule ZahlungsWeb.ShiftLive.Index do
  @moduledoc """
  Shift history. Cashiers see their own shifts; admins see everyone's. A detail
  modal shows the reconciliation and the sales made during the shift.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Shifts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_shifts(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(page_title: "Shifts", shift: nil, sales: [], summary: nil, movements: [])
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    shift = Shifts.get_shift!(socket.assigns.current_scope, id)
    user = socket.assigns.current_user

    if shift.user_id == user.id or user.role == "admin" do
      socket
      |> assign(:page_title, "Shift ##{shift.id}")
      |> assign(:shift, shift)
      |> assign(:sales, Shifts.shift_sales(shift))
      |> assign(:summary, Shifts.shift_summary(shift))
      |> assign(:movements, Shifts.list_cash_movements(shift))
    else
      socket
      |> put_flash(:error, "You can only view your own shifts.")
      |> push_navigate(to: ~p"/shifts")
    end
  end

  defp load_shifts(socket) do
    user = socket.assigns.current_user
    opts = if user.role == "admin", do: [], else: [user_id: user.id]
    assign(socket, :shifts, Shifts.list_shifts(socket.assigns.current_scope, opts))
  end

  defp fmt(nil, _store), do: "—"

  defp fmt(%NaiveDateTime{} = dt, store),
    do: Calendar.strftime(Zahlungs.LocalTime.to_local(dt, store), "%d %b %Y %H:%M")

  defp cashier_name(nil), do: "—"
  defp cashier_name(%{name: name}) when name not in [nil, ""], do: name
  defp cashier_name(%{email: email}), do: email

  defp payment_label("cash"), do: "Tunai"
  defp payment_label("qris"), do: "QRIS"
  defp payment_label("card"), do: "Kartu"
  defp payment_label("transfer"), do: "Transfer"
  defp payment_label(other), do: other

  defp movement_label("expense"), do: "Pengeluaran"
  defp movement_label("cash_drop"), do: "Setor brankas"
  defp movement_label("cash_in"), do: "Uang masuk"
  defp movement_label("consignment_payment"), do: "Bayar konsinyasi"
  defp movement_label("refund"), do: "Refund retur"
  defp movement_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Shifts
      <:subtitle>Riwayat sesi kas</:subtitle>
    </.header>

    <.table id="shifts" rows={@shifts}>
      <:col :let={shift} label="#">{shift.id}</:col>
      <:col :let={shift} :if={is_nil(@current_scope.store)} label="Store">{shift.store.name}</:col>
      <:col :let={shift} label="Cashier">
        <div>{cashier_name(shift.user)}</div>
        <div :if={shift.user && shift.user.name not in [nil, ""]} class="text-xs text-gray-400">
          {shift.user.email}
        </div>
      </:col>
      <:col :let={shift} label="Opened">{fmt(shift.opened_at, shift.store)}</:col>
      <:col :let={shift} label="Closed">{fmt(shift.closed_at, shift.store)}</:col>
      <:col :let={shift} label="Status">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (shift.status == "open" && "bg-green-100 text-green-700") || "bg-gray-100 text-gray-700"
        ]}>
          {shift.status}
        </span>
      </:col>
      <:col :let={shift} label="Variance">
        <span :if={shift.status == "closed"} class={variance_class(shift.variance)}>
          {format_money(shift.variance)}
        </span>
        <span :if={shift.status == "open"} class="text-gray-400">—</span>
      </:col>
      <:action :let={shift}>
        <.link patch={~p"/shifts/#{shift}"}>View</.link>
      </:action>
    </.table>

    <.modal :if={@live_action == :show and @shift} id="shift-modal" show on_cancel={JS.patch(~p"/shifts")}>
      <h3 class="text-lg font-semibold">Shift #{@shift.id}</h3>
      <p class="text-sm text-gray-600">{cashier_name(@shift.user)}</p>
      <p class="text-xs text-gray-400">
        {@shift.user && @shift.user.email} · opened {fmt(@shift.opened_at, @shift.store)} · closed {fmt(@shift.closed_at, @shift.store)}
      </p>

      <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
        <div class="flex justify-between"><dt>Opening cash</dt><dd>{format_money(@shift.opening_cash)}</dd></div>
        <div class="flex justify-between"><dt>Transactions</dt><dd>{@summary.transactions}</dd></div>
        <div class="flex justify-between"><dt>Cash sales</dt><dd>{format_money(@summary.cash_total)}</dd></div>
        <div class="flex justify-between text-gray-500">
          <dt>Non-cash sales (QRIS/kartu/transfer)</dt><dd>{format_money(@summary.noncash_total)}</dd>
        </div>
        <div :if={not Decimal.equal?(@summary.cash_in, Decimal.new(0))} class="flex justify-between text-green-700">
          <dt>Cash in</dt><dd>+{format_money(@summary.cash_in)}</dd>
        </div>
        <div :if={not Decimal.equal?(@summary.cash_out, Decimal.new(0))} class="flex justify-between text-red-600">
          <dt>Cash out</dt><dd>−{format_money(@summary.cash_out)}</dd>
        </div>
        <div class="flex justify-between font-semibold"><dt>Expected cash</dt><dd>{format_money(@summary.expected_cash)}</dd></div>
        <div :if={@shift.status == "closed"} class="flex justify-between">
          <dt>Counted cash</dt><dd>{format_money(@shift.counted_cash)}</dd>
        </div>
        <div :if={@shift.status == "closed"} class="flex justify-between font-semibold">
          <dt>Variance</dt>
          <dd class={variance_class(@shift.variance)}>{format_money(@shift.variance)}</dd>
        </div>
        <div :if={@shift.note not in [nil, ""]} class="flex justify-between">
          <dt>Note</dt><dd class="text-gray-600">{@shift.note}</dd>
        </div>
      </dl>

      <h4 class="mt-6 font-semibold text-gray-700">Transactions</h4>
      <.table id="shift-sales" rows={@sales}>
        <:col :let={sale} label="Code">{sale.code}</:col>
        <:col :let={sale} label="Time">{Calendar.strftime(Zahlungs.LocalTime.to_local(sale.inserted_at, @shift.store), "%H:%M")}</:col>
        <:col :let={sale} label="Items">{length(sale.items)}</:col>
        <:col :let={sale} label="Method">{payment_label(sale.payment_method)}</:col>
        <:col :let={sale} label="Total">{format_money(sale.total)}</:col>
        <:col :let={sale} label="Status">{sale.status}</:col>
      </.table>

      <h4 :if={@movements != []} class="mt-6 font-semibold text-gray-700">Gerakan kas</h4>
      <.table :if={@movements != []} id="shift-movements" rows={@movements}>
        <:col :let={m} label="Time">{Calendar.strftime(Zahlungs.LocalTime.to_local(m.inserted_at, @shift.store), "%H:%M")}</:col>
        <:col :let={m} label="Tipe">{movement_label(m.category)}</:col>
        <:col :let={m} label="Supplier">{m.supplier && m.supplier.name}</:col>
        <:col :let={m} label="Catatan">{m.note}</:col>
        <:col :let={m} label="Jumlah">
          <span class={if m.direction == "in", do: "text-green-700", else: "text-red-600"}>
            {if m.direction == "in", do: "+", else: "−"}{format_money(m.amount)}
          </span>
        </:col>
      </.table>
    </.modal>
    """
  end

  defp variance_class(variance) do
    cond do
      is_nil(variance) -> "text-gray-600"
      Decimal.equal?(variance, Decimal.new(0)) -> "text-gray-600"
      Decimal.negative?(variance) -> "text-red-600"
      true -> "text-green-600"
    end
  end
end
