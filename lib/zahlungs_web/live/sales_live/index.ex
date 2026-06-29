defmodule ZahlungsWeb.SalesLive.Index do
  @moduledoc """
  Sales / transaction history: list recent sales with an optional date filter and
  a detail modal. Available to any authenticated user.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Sales

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:date, "")
     |> load_sales()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sales")
    |> assign(:sale, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(:page_title, "Sale detail")
    |> assign(:sale, Sales.get_sale!(id))
  end

  @impl true
  def handle_event("filter", %{"date" => date}, socket) do
    {:noreply, socket |> assign(:date, date) |> load_sales()}
  end

  def handle_event("return", %{"id" => id}, socket) do
    if socket.assigns.current_user.role == "admin" do
      sale = Sales.get_sale!(id)

      case Sales.return_sale(sale) do
        {:ok, _returned} ->
          {:noreply,
           socket
           |> put_flash(:info, "Sale #{sale.code} returned; stock restored.")
           |> load_sales()
           |> push_patch(to: ~p"/sales")}

        {:error, :already_returned} ->
          {:noreply, put_flash(socket, :error, "This sale has already been returned.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not return the sale.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to return sales.")}
    end
  end

  defp load_sales(socket) do
    assign(socket, :sales, Sales.list_sales(date: parse_date(socket.assigns.date)))
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end


  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Sales
      <:subtitle>Riwayat transaksi</:subtitle>
    </.header>

    <form phx-change="filter" class="mt-6 flex items-end gap-3">
      <label class="text-sm">
        Filter by date
        <input type="date" name="date" value={@date} class="form-control" />
      </label>
    </form>

    <.table id="sales" rows={@sales}>
      <:col :let={sale} label="Code">{sale.code}</:col>
      <:col :let={sale} label="Date">{Calendar.strftime(sale.inserted_at, "%d %b %Y %H:%M")}</:col>
      <:col :let={sale} label="Cashier">{sale.user && sale.user.email}</:col>
      <:col :let={sale} label="Items">{length(sale.items)}</:col>
      <:col :let={sale} label="Total">{format_money(sale.total)}</:col>
      <:col :let={sale} label="Status">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (sale.status == "returned" && "bg-red-100 text-red-700") || "bg-green-100 text-green-700"
        ]}>
          {sale.status}
        </span>
      </:col>
      <:action :let={sale}>
        <.link patch={~p"/sales/#{sale}"}>View</.link>
      </:action>
    </.table>

    <.modal :if={@live_action == :show and @sale} id="sale-modal" show on_cancel={JS.patch(~p"/sales")}>
      <h3 class="text-lg font-semibold">Sale {@sale.code}</h3>

      <.sale_receipt sale={@sale} />

      <div class="mt-2 flex justify-between text-sm">
        <dt>Status</dt>
        <dd class={(@sale.status == "returned" && "text-red-600") || "text-green-600"}>
          {@sale.status}
        </dd>
      </div>

      <div class="mt-6 flex items-center justify-between gap-3">
        <.link
          href={~p"/sales/#{@sale.id}/receipt"}
          target="_blank"
          class="btn btn-sm btn-link"
        >
          Print receipt
        </.link>
        <.button
          :if={@current_user.role == "admin" and @sale.status == "completed"}
          phx-click={JS.push("return", value: %{id: @sale.id})}
          data-confirm="Return this sale and restore stock? This cannot be undone."
          class="!bg-red-600"
        >
          Return / Refund
        </.button>
      </div>
    </.modal>
    """
  end
end
