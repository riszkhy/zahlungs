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
    socket |> assign(page_title: "Shifts", shift: nil, sales: [], summary: nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    shift = Shifts.get_shift!(id)
    user = socket.assigns.current_user

    if shift.user_id == user.id or user.role == "admin" do
      socket
      |> assign(:page_title, "Shift ##{shift.id}")
      |> assign(:shift, shift)
      |> assign(:sales, Shifts.shift_sales(shift))
      |> assign(:summary, Shifts.shift_summary(shift))
    else
      socket
      |> put_flash(:error, "You can only view your own shifts.")
      |> push_navigate(to: ~p"/shifts")
    end
  end

  defp load_shifts(socket) do
    user = socket.assigns.current_user
    opts = if user.role == "admin", do: [], else: [user_id: user.id]
    assign(socket, :shifts, Shifts.list_shifts(opts))
  end

  defp fmt(nil), do: "—"
  defp fmt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y %H:%M")

  defp cashier_name(nil), do: "—"
  defp cashier_name(%{name: name}) when name not in [nil, ""], do: name
  defp cashier_name(%{email: email}), do: email

  defp payment_label("cash"), do: "Tunai"
  defp payment_label("qris"), do: "QRIS"
  defp payment_label("card"), do: "Kartu"
  defp payment_label("transfer"), do: "Transfer"
  defp payment_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Shifts
      <:subtitle>Riwayat sesi kas</:subtitle>
    </.header>

    <.table id="shifts" rows={@shifts}>
      <:col :let={shift} label="#">{shift.id}</:col>
      <:col :let={shift} label="Cashier">
        <div>{cashier_name(shift.user)}</div>
        <div :if={shift.user && shift.user.name not in [nil, ""]} class="text-xs text-gray-400">
          {shift.user.email}
        </div>
      </:col>
      <:col :let={shift} label="Opened">{fmt(shift.opened_at)}</:col>
      <:col :let={shift} label="Closed">{fmt(shift.closed_at)}</:col>
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
        {@shift.user && @shift.user.email} · opened {fmt(@shift.opened_at)} · closed {fmt(@shift.closed_at)}
      </p>

      <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
        <div class="flex justify-between"><dt>Opening cash</dt><dd>{format_money(@shift.opening_cash)}</dd></div>
        <div class="flex justify-between"><dt>Transactions</dt><dd>{@summary.transactions}</dd></div>
        <div class="flex justify-between"><dt>Cash sales</dt><dd>{format_money(@summary.cash_total)}</dd></div>
        <div class="flex justify-between text-gray-500">
          <dt>Non-cash sales (QRIS/kartu/transfer)</dt><dd>{format_money(@summary.noncash_total)}</dd>
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
        <:col :let={sale} label="Time">{Calendar.strftime(sale.inserted_at, "%H:%M")}</:col>
        <:col :let={sale} label="Items">{length(sale.items)}</:col>
        <:col :let={sale} label="Method">{payment_label(sale.payment_method)}</:col>
        <:col :let={sale} label="Total">{format_money(sale.total)}</:col>
        <:col :let={sale} label="Status">{sale.status}</:col>
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
