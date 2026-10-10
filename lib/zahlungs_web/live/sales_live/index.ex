defmodule ZahlungsWeb.SalesLive.Index do
  @moduledoc """
  Sales / transaction history: paged list of sales (most recent first) with an
  optional date filter and a detail modal. Available to any authenticated user.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Sales

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(date: "", page: 1)
     |> assign(:voiding, nil)
     |> assign(:void_reason, "")
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
    |> assign(:sale, Sales.get_sale!(socket.assigns.current_scope, id))
  end

  @impl true
  def handle_event("filter", %{"date" => date}, socket) do
    {:noreply, socket |> assign(date: date, page: 1) |> load_sales()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    {:noreply, socket |> assign(:page, max(1, to_int(to))) |> load_sales()}
  end

  def handle_event("return", %{"id" => id}, socket) do
    if socket.assigns.current_user.role == "admin" do
      sale = Sales.get_sale!(socket.assigns.current_scope, id)

      case Sales.return_sale(sale, socket.assigns.current_user) do
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

  def handle_event("prompt_void", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, voiding: Sales.get_sale!(socket.assigns.current_scope, id), void_reason: "")}
  end

  def handle_event("cancel_void", _params, socket) do
    {:noreply, assign(socket, voiding: nil, void_reason: "")}
  end

  def handle_event("void_change", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :void_reason, reason)}
  end

  def handle_event("do_void", %{"reason" => reason}, socket) do
    user = socket.assigns.current_user
    sale = socket.assigns.voiding

    cond do
      is_nil(sale) ->
        {:noreply, socket}

      user.role != "admin" and sale.user_id != user.id ->
        {:noreply,
         socket
         |> assign(voiding: nil)
         |> put_flash(:error, "Anda hanya bisa membatalkan penjualan sendiri.")}

      true ->
        case Sales.void_sale(sale, user, reason) do
          {:ok, _voided} ->
            {:noreply,
             socket
             |> assign(voiding: nil, void_reason: "")
             |> put_flash(:info, "Penjualan #{sale.code} dibatalkan; stok dikembalikan.")
             |> load_sales()
             |> push_patch(to: ~p"/sales")}

          {:error, :shift_closed} ->
            {:noreply,
             socket
             |> assign(voiding: nil)
             |> put_flash(:error, "Shift sudah ditutup — pembatalan butuh admin.")}

          {:error, :not_voidable} ->
            {:noreply,
             socket
             |> assign(voiding: nil)
             |> put_flash(:error, "Penjualan ini tidak bisa dibatalkan.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Gagal membatalkan (cek alasan).")}
        end
    end
  end

  defp load_sales(socket) do
    scope = socket.assigns.current_scope
    date = parse_date(socket.assigns.date)
    total = Sales.count_sales(scope, date: date)
    total_pages = max(1, ceil(total / @per_page))
    page = min(socket.assigns.page, total_pages)

    sales = Sales.list_sales(scope, date: date, limit: @per_page, offset: (page - 1) * @per_page)

    assign(socket, sales: sales, total: total, total_pages: total_pages, page: page)
  end

  # JS.push sends numbers as JSON numbers; a form would send strings.
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)

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
      <:col :let={sale} label="Date">{Calendar.strftime(Zahlungs.LocalTime.to_local(sale.inserted_at, sale.store), "%d %b %Y %H:%M")}</:col>
      <:col :let={sale} :if={is_nil(@current_scope.store)} label="Store">{sale.store.name}</:col>
      <:col :let={sale} label="Cashier">{sale.user && sale.user.email}</:col>
      <:col :let={sale} label="Items">{length(sale.items)}</:col>
      <:col :let={sale} label="Total">{format_money(sale.total)}</:col>
      <:col :let={sale} label="Status">
        <span class={["text-xs px-2 py-0.5 rounded-full", status_badge_class(sale.status)]}>
          {sale.status}
        </span>
      </:col>
      <:action :let={sale}>
        <.link patch={~p"/sales/#{sale}"}>View</.link>
      </:action>
    </.table>

    <div :if={@total_pages > 1} class="mt-6 flex items-center justify-center gap-4">
      <.button
        phx-click={JS.push("page", value: %{to: @page - 1})}
        disabled={@page <= 1}
        class="!bg-gray-200 !text-gray-700"
      >
        Prev
      </.button>
      <span class="text-sm text-gray-600">Page {@page} of {@total_pages} · {@total} sales</span>
      <.button
        phx-click={JS.push("page", value: %{to: @page + 1})}
        disabled={@page >= @total_pages}
        class="!bg-gray-200 !text-gray-700"
      >
        Next
      </.button>
    </div>

    <.modal :if={@live_action == :show and @sale} id="sale-modal" show on_cancel={JS.patch(~p"/sales")}>
      <h3 class="text-lg font-semibold">Sale {@sale.code}</h3>

      <.sale_receipt sale={@sale} />

      <div class="mt-2 flex justify-between text-sm">
        <dt>Status</dt>
        <dd class={status_text_class(@sale.status)}>{@sale.status}</dd>
      </div>
      <div :if={@sale.status == "void" and @sale.void_reason} class="mt-1 flex justify-between text-sm">
        <dt>Alasan batal</dt>
        <dd class="text-gray-600">{@sale.void_reason}</dd>
      </div>

      <div class="mt-6 flex items-center justify-between gap-3">
        <.link
          href={~p"/sales/#{@sale.id}/receipt"}
          target="_blank"
          class="btn btn-sm btn-link"
        >
          Print receipt
        </.link>
        <div class="flex items-center gap-2">
          <.button
            :if={@sale.status == "completed" and (@current_user.role == "admin" or @sale.user_id == @current_user.id)}
            phx-click={JS.push("prompt_void", value: %{id: @sale.id})}
            class="!bg-amber-600"
          >
            Batalkan (koreksi)
          </.button>
          <.button
            :if={@current_user.role == "admin" and @sale.status == "completed"}
            phx-click={JS.push("return", value: %{id: @sale.id})}
            data-confirm="Return this sale and restore stock? This cannot be undone."
            class="!bg-red-600"
          >
            Return / Refund
          </.button>
        </div>
      </div>
    </.modal>

    <.modal :if={@voiding} id="void-modal" show on_cancel={JS.push("cancel_void")}>
      <h3 class="text-lg font-semibold">Batalkan penjualan {@voiding.code}</h3>
      <p class="mt-1 text-sm text-gray-500">
        Invoice akan ditandai <strong>void</strong> dan stok dikembalikan. Setelah ini,
        input ulang transaksi yang benar di halaman Cashier.
      </p>

      <form phx-change="void_change" phx-submit="do_void" class="mt-4 space-y-3">
        <label class="block text-sm">
          Alasan koreksi
          <input type="text" name="reason" value={@void_reason} required class="form-control" placeholder="mis. salah qty / salah produk" />
        </label>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="cancel_void" class="btn btn-sm">Batal</button>
          <.button class="!bg-amber-600">Konfirmasi batalkan</.button>
        </div>
      </form>
    </.modal>
    """
  end

  defp status_badge_class("returned"), do: "bg-red-100 text-red-700"
  defp status_badge_class("void"), do: "bg-gray-200 text-gray-700"
  defp status_badge_class(_), do: "bg-green-100 text-green-700"

  defp status_text_class("returned"), do: "text-red-600"
  defp status_text_class("void"), do: "text-gray-600"
  defp status_text_class(_), do: "text-green-600"
end
