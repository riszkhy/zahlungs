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
     |> assign(date: "", page: 1, per_page: @per_page)
     |> assign(:voiding, nil)
     |> assign(:void_reason, "")
     |> assign(:returning, nil)
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

  def handle_event("prompt_return", %{"id" => id}, socket) do
    if socket.assigns.current_user.role == "admin" do
      {:noreply, assign(socket, :returning, Sales.get_sale!(socket.assigns.current_scope, id))}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to return sales.")}
    end
  end

  def handle_event("cancel_return", _params, socket) do
    {:noreply, assign(socket, :returning, nil)}
  end

  # Only while the popup is open, so a second click does nothing.
  def handle_event("confirm_return", _params, %{assigns: %{returning: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_return", _params, socket) do
    if socket.assigns.current_user.role == "admin" do
      scope = socket.assigns.current_scope
      sale = Sales.get_sale!(scope, socket.assigns.returning.id)
      socket = assign(socket, :returning, nil)

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
      {:noreply,
       socket
       |> assign(:returning, nil)
       |> put_flash(:error, "You do not have permission to return sales.")}
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
    <div class="md3 -m-6 rounded-xl bg-surface p-4 text-on-surface">
      <h1 class="text-headline-sm">Sales</h1>
      <p class="text-body-md text-on-surface-variant">Riwayat transaksi</p>

      <form phx-change="filter" class="mt-4 max-w-xs">
        <.md_text_field type="date" name="date" value={@date} label="Filter by date" />
      </form>

      <%!-- Below landscape-tablet width a row doesn't fit: one tappable card per sale. --%>
      <div class="mt-4 space-y-2 lg:hidden">
        <.link
          :for={sale <- @sales}
          id={"sale-card-#{sale.id}"}
          patch={~p"/sales/#{sale}"}
          class="md-state flex items-center gap-3 rounded-md3-md border border-outline-variant bg-surface p-3"
        >
          <span class="min-w-0 flex-1">
            <span class="block truncate text-title-sm">{sale.code}</span>
            <span class="block text-body-sm text-on-surface-variant">
              {sale_time(sale)} · {length(sale.items)} item
              <span :if={is_nil(@current_scope.store)}>· {sale.store.name}</span>
            </span>
          </span>
          <span class="flex shrink-0 flex-col items-end gap-1">
            <span class="text-title-sm">{format_money(sale.total)}</span>
            <.status_badge status={sale.status} />
          </span>
        </.link>
        <p :if={@sales == []} class="text-body-md text-on-surface-variant">Belum ada penjualan.</p>
      </div>

      <div id="sales" class="mt-4 hidden overflow-x-auto rounded-md3-lg bg-surface-container-low lg:block">
        <table class="w-full text-body-md">
          <thead class="text-left text-label-lg text-on-surface-variant">
            <tr>
              <th class="px-4 py-3">Code</th>
              <th class="px-4 py-3">Date</th>
              <th :if={is_nil(@current_scope.store)} class="px-4 py-3">Store</th>
              <th class="px-4 py-3">Cashier</th>
              <th class="px-4 py-3">Items</th>
              <th class="px-4 py-3 text-right">Total</th>
              <th class="px-4 py-3">Status</th>
              <th class="px-4 py-3"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={sale <- @sales} id={"sales-#{sale.id}"} class="border-t border-outline-variant">
              <td class="px-4 py-2 font-medium">{sale.code}</td>
              <td class="whitespace-nowrap px-4 py-2">{sale_time(sale)}</td>
              <td :if={is_nil(@current_scope.store)} class="px-4 py-2">{sale.store.name}</td>
              <td class="px-4 py-2">{sale.user && sale.user.email}</td>
              <td class="px-4 py-2">{length(sale.items)}</td>
              <td class="whitespace-nowrap px-4 py-2 text-right">{format_money(sale.total)}</td>
              <td class="px-4 py-2"><.status_badge status={sale.status} /></td>
              <td class="px-4 py-2 text-right">
                <.link
                  patch={~p"/sales/#{sale}"}
                  class="md-state inline-flex h-8 items-center rounded-full px-2 text-label-lg text-primary"
                >
                  View
                </.link>
              </td>
            </tr>
            <tr :if={@sales == []}>
              <td colspan="8" class="px-4 py-3 text-on-surface-variant">Belum ada penjualan.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} per_page={@per_page} total={@total} noun="penjualan" />
    </div>

    <.md_dialog
      :if={@live_action == :show and @sale}
      id="sale-modal"
      show
      on_cancel={JS.patch(~p"/sales")}
    >
      <:title>Sale {@sale.code}</:title>

      <.sale_receipt sale={@sale} />

      <dl class="mt-2 space-y-1 text-body-md">
        <div class="flex items-center justify-between">
          <dt>Status</dt>
          <dd><.status_badge status={@sale.status} /></dd>
        </div>
        <div :if={@sale.status == "void" and @sale.void_reason} class="flex justify-between gap-4">
          <dt>Alasan batal</dt>
          <dd class="text-right text-on-surface-variant">{@sale.void_reason}</dd>
        </div>
      </dl>

      <:actions>
        <.md_button
          variant="text"
          href={~p"/sales/#{@sale.id}/receipt"}
          target="_blank"
          rel="noopener"
        >
          Print receipt
        </.md_button>
        <.md_button
          :if={
            @sale.status == "completed" and
              (@current_user.role == "admin" or @sale.user_id == @current_user.id)
          }
          variant="tonal"
          type="button"
          phx-click={JS.push("prompt_void", value: %{id: @sale.id})}
        >
          Batalkan (koreksi)
        </.md_button>
        <.md_button
          :if={@current_user.role == "admin" and @sale.status == "completed"}
          variant="danger"
          type="button"
          phx-click={JS.push("prompt_return", value: %{id: @sale.id})}
        >
          Return / Refund
        </.md_button>
      </:actions>
    </.md_dialog>

    <.md_dialog :if={@voiding} id="void-modal" show on_cancel={JS.push("cancel_void")}>
      <:title>Batalkan penjualan {@voiding.code}</:title>
      <p class="mt-1 text-body-md text-on-surface-variant">
        Invoice akan ditandai <strong>void</strong> dan stok dikembalikan. Setelah ini,
        input ulang transaksi yang benar di halaman Cashier.
      </p>

      <form id="void-form" phx-change="void_change" phx-submit="do_void" class="mt-4">
        <.md_text_field
          name="reason"
          value={@void_reason}
          label="Alasan koreksi"
          required
          placeholder="mis. salah qty / salah produk"
        />
      </form>

      <:actions>
        <.md_button variant="text" type="button" phx-click="cancel_void">Batal</.md_button>
        <.md_button type="submit" form="void-form">Konfirmasi batalkan</.md_button>
      </:actions>
    </.md_dialog>

    <.md_dialog :if={@returning} id="return-modal" show on_cancel={JS.push("cancel_return")}>
      <:title>Return penjualan {@returning.code}</:title>
      <p class="mt-2 text-body-lg font-medium">{format_money(@returning.total)}</p>
      <p class="mt-2 text-body-md text-on-surface-variant">
        Penjualan ditandai <strong>returned</strong>, stok dikembalikan ke cabang penjualan,
        dan uang tunai dikembalikan dari laci (penjualan piutang: uang mukanya saja).
        Ini tidak bisa dibatalkan.
      </p>
      <:actions>
        <.md_button variant="text" type="button" phx-click="cancel_return">Batal</.md_button>
        <.md_button
          variant="danger"
          type="button"
          phx-click="confirm_return"
          phx-disable-with="Memproses..."
        >
          Return
        </.md_button>
      </:actions>
    </.md_dialog>
    """
  end

  defp sale_time(sale) do
    Calendar.strftime(Zahlungs.LocalTime.to_local(sale.inserted_at, sale.store), "%d %b %Y %H:%M")
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <.md_badge tone={status_tone(@status)}>{@status}</.md_badge>
    """
  end

  defp status_tone("completed"), do: "success"
  defp status_tone("returned"), do: "error"
  defp status_tone(_), do: "neutral"
end
