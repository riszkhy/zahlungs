defmodule ZahlungsWeb.CashierLive do
  @moduledoc """
  Cashier / point-of-sale screen: search products, build a cart, take payment,
  and complete a transaction (which records the sale and decrements stock).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Sales, Shifts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Cashier", last_sale: nil, scanning: false)
     |> assign(opening_cash: "", closing: false, counted_cash: "", close_note: "", summary: nil)
     |> assign(:shift, Shifts.current_shift(socket.assigns.current_user))
     |> reset_cart()}
  end

  @impl true
  def handle_event("open_shift", %{"opening_cash" => opening_cash}, socket) do
    case Shifts.open_shift(socket.assigns.current_user, opening_cash) do
      {:ok, shift} ->
        {:noreply, socket |> assign(:shift, shift) |> put_flash(:info, "Shift opened.")}

      {:error, :already_open} ->
        {:noreply,
         socket
         |> assign(:shift, Shifts.current_shift(socket.assigns.current_user))
         |> put_flash(:error, "You already have an open shift.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not open shift (check the opening cash).")}
    end
  end

  def handle_event("toggle_close", _params, socket) do
    {:noreply,
     socket
     |> assign(:closing, not socket.assigns.closing)
     |> assign(:summary, socket.assigns.shift && Shifts.shift_summary(socket.assigns.shift))
     |> assign(counted_cash: "", close_note: "")}
  end

  def handle_event("close_change", params, socket) do
    {:noreply,
     assign(socket, counted_cash: params["counted_cash"] || "", close_note: params["note"] || "")}
  end

  def handle_event("close_shift", %{"counted_cash" => counted, "note" => note}, socket) do
    case Shifts.close_shift(socket.assigns.shift, counted, note) do
      {:ok, closed} ->
        {:noreply,
         socket
         |> assign(shift: nil, closing: false)
         |> put_flash(:info, "Shift closed. Variance: #{format_money(closed.variance)}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not close the shift.")}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    results =
      if String.trim(q) == "" do
        []
      else
        Catalog.list_products(search: q, active: true, in_stock: true, limit: 8)
      end

    {:noreply, assign(socket, search: q, results: results)}
  end

  # Submit (Enter) — also fired by a barcode scanner after it "types" the code.
  # An exact barcode/SKU match is added to the cart and the box is cleared so the
  # next item can be scanned immediately.
  def handle_event("scan", %{"q" => code}, socket) do
    case Catalog.get_product_by_code(code) do
      nil ->
        {:noreply,
         socket
         |> assign(search: code)
         |> push_event("beep", %{type: "error"})
         |> put_flash(:error, "No product found for \"#{String.trim(code)}\".")}

      %{stock: stock} when stock <= 0 ->
        {:noreply,
         socket
         |> push_event("beep", %{type: "error"})
         |> put_flash(:error, "Product is out of stock.")}

      product ->
        {:noreply,
         socket
         |> add_to_cart(product)
         |> assign(search: "", results: [])
         |> assign_totals()
         |> push_event("beep", %{type: "ok"})
         |> put_flash(:info, "Added #{product.name}.")}
    end
  end

  def handle_event("toggle_camera", _params, socket) do
    {:noreply, assign(socket, :scanning, not socket.assigns.scanning)}
  end

  def handle_event("camera_unsupported", _params, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(:error, "Camera scanning isn't supported on this browser. Use a USB scanner or type the code.")}
  end

  def handle_event("camera_error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(:error, "Could not start the camera: #{message}")}
  end

  def handle_event("add", %{"id" => id}, socket) do
    id = to_int(id)
    product = Enum.find(socket.assigns.results, &(&1.id == id))

    socket =
      if product,
        do: socket |> add_to_cart(product) |> push_event("beep", %{type: "ok"}),
        else: socket

    {:noreply, assign_totals(socket)}
  end

  def handle_event("inc", %{"id" => id}, socket) do
    id = to_int(id)
    item = Enum.find(socket.assigns.cart, &(&1.product_id == id))
    socket = if item, do: update_qty(socket, id, item.quantity + 1), else: socket
    {:noreply, assign_totals(socket)}
  end

  def handle_event("dec", %{"id" => id}, socket) do
    id = to_int(id)
    item = Enum.find(socket.assigns.cart, &(&1.product_id == id))

    socket =
      cond do
        is_nil(item) -> socket
        item.quantity <= 1 -> remove_item(socket, id)
        true -> update_qty(socket, id, item.quantity - 1)
      end

    {:noreply, assign_totals(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    {:noreply, socket |> remove_item(to_int(id)) |> assign_totals()}
  end

  def handle_event("set_amount_paid", %{"value" => value}, socket) do
    {:noreply, socket |> assign(:amount_paid, value) |> assign_totals()}
  end

  def handle_event("set_payment_method", %{"method" => method}, socket)
      when method in ~w(cash qris card transfer) do
    {:noreply, socket |> assign(:payment_method, method) |> assign_totals()}
  end

  def handle_event("payment", params, socket) do
    {:noreply,
     socket
     |> assign(
       discount: params["discount"] || "",
       tax: params["tax"] || "",
       amount_paid: params["amount_paid"] || ""
     )
     |> assign_totals()}
  end

  def handle_event("checkout", _params, socket) do
    cart = Enum.map(socket.assigns.cart, &%{product_id: &1.product_id, quantity: &1.quantity})

    payment = %{
      amount_paid: socket.assigns.amount_paid,
      discount: socket.assigns.discount,
      tax: socket.assigns.tax,
      payment_method: socket.assigns.payment_method,
      shift_id: socket.assigns.shift && socket.assigns.shift.id
    }

    case Sales.create_sale(socket.assigns.current_user, cart, payment) do
      {:ok, sale} ->
        {:noreply,
         socket
         |> assign(:last_sale, sale)
         |> reset_cart()
         |> push_event("reset_amount_paid", %{})
         |> put_flash(:info, "Sale #{sale.code} completed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("new_sale", _params, socket) do
    {:noreply, socket |> assign(:last_sale, nil) |> reset_cart() |> push_event("reset_amount_paid", %{})}
  end

  ## Cart helpers

  defp add_to_cart(socket, product) do
    case Enum.find(socket.assigns.cart, &(&1.product_id == product.id)) do
      nil ->
        item = %{
          product_id: product.id,
          name: product.name,
          sku: product.sku,
          unit_price: product.price,
          quantity: 1,
          stock: product.stock
        }

        assign(socket, :cart, socket.assigns.cart ++ [item])

      existing ->
        update_qty(socket, product.id, existing.quantity + 1)
    end
  end

  defp update_qty(socket, id, qty) do
    cart =
      Enum.map(socket.assigns.cart, fn item ->
        if item.product_id == id,
          do: %{item | quantity: qty |> min(item.stock) |> max(1)},
          else: item
      end)

    assign(socket, :cart, cart)
  end

  defp remove_item(socket, id) do
    assign(socket, :cart, Enum.reject(socket.assigns.cart, &(&1.product_id == id)))
  end

  defp reset_cart(socket) do
    socket
    |> assign(cart: [], discount: "", tax: "", amount_paid: "", payment_method: "cash", search: "", results: [])
    |> assign_totals()
  end

  defp assign_totals(socket) do
    subtotal = cart_subtotal(socket.assigns.cart)
    discount = to_dec(socket.assigns.discount)
    tax = to_dec(socket.assigns.tax)
    total = subtotal |> Decimal.sub(discount) |> Decimal.add(tax)
    cash? = socket.assigns.payment_method == "cash"
    # Non-cash is settled for the exact total: no tendered amount, no change.
    paid = if cash?, do: to_dec(socket.assigns.amount_paid), else: total
    change = if cash?, do: Decimal.sub(paid, total), else: Decimal.new(0)

    total_ok = not Decimal.lt?(total, Decimal.new(0))
    paid_ok = not cash? or not Decimal.lt?(paid, total)

    assign(socket,
      subtotal: subtotal,
      total: total,
      change_due: change,
      can_checkout: socket.assigns[:shift] != nil and socket.assigns.cart != [] and total_ok and paid_ok
    )
  end

  defp cart_subtotal(cart) do
    Enum.reduce(cart, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
    end)
  end

  # JS.push value:%{id: ...} sends the id as a JSON number (integer), but form
  # params would send a string — handle both.
  defp to_int(id) when is_integer(id), do: id
  defp to_int(id) when is_binary(id), do: String.to_integer(id)

  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d

  defp to_dec(s) when is_binary(s) do
    case s |> String.trim() |> Decimal.parse() do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp to_dec(_), do: Decimal.new(0)


  defp error_message(:empty_cart), do: "Cart is empty."
  defp error_message(:insufficient_payment), do: "Amount paid is less than the total."
  defp error_message({:insufficient_stock, name}), do: "Insufficient stock for #{name}."
  defp error_message(_), do: "Could not complete the sale."

  defp payment_method_options do
    [{"cash", "Tunai"}, {"qris", "QRIS"}, {"card", "Kartu"}, {"transfer", "Transfer"}]
  end

  defp payment_method_label(method) do
    payment_method_options() |> List.keyfind(method, 0) |> case do
      {_value, label} -> label
      nil -> method
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="cashier-beeper" phx-hook="Beeper" class="hidden"></div>

    <.header>
      Cashier
      <:subtitle>Layar transaksi penjualan</:subtitle>
    </.header>

    <div :if={is_nil(@shift)} class="mt-6 max-w-sm rounded-lg border border-gray-200 p-6 shadow-sm">
      <h3 class="font-semibold text-gray-700">Open shift</h3>
      <p class="mt-1 text-sm text-gray-500">
        You must open a shift (enter the opening cash) before making sales.
      </p>
      <form phx-submit="open_shift" class="mt-4">
        <label class="block text-sm">
          Opening cash (modal awal)
          <input type="number" name="opening_cash" value={@opening_cash} min="0" step="1" required class="form-control" />
        </label>
        <.button class="mt-4 w-full">Open Shift</.button>
      </form>
    </div>

    <div :if={@shift} class="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-green-200 bg-green-50 p-3 text-sm">
      <span class="text-gray-700">
        Shift #{@shift.id} · opened {Calendar.strftime(@shift.opened_at, "%d %b %Y %H:%M")} · float {format_money(@shift.opening_cash)}
      </span>
      <button type="button" phx-click="toggle_close" class="font-medium text-red-600 hover:underline">
        Close shift
      </button>
    </div>

    <div :if={@shift} class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-8">
      <%!-- Product search --%>
      <div>
        <form phx-change="search" phx-submit="scan">
          <input
            type="text"
            name="q"
            value={@search}
            placeholder="Scan barcode or search by name / SKU, then Enter..."
            phx-debounce="200"
            autocomplete="off"
            class="form-control"
          />
          <p class="mt-1 text-xs text-gray-400">
            Tip: a barcode scanner types the code and presses Enter to add the item.
          </p>
        </form>

        <button type="button" phx-click="toggle_camera" class="mt-2 text-sm text-blue-600 hover:underline">
          {if @scanning, do: "■ Stop camera", else: "📷 Scan with camera"}
        </button>

        <div :if={@scanning} class="mt-2">
          <video
            id="cashier-scanner"
            phx-hook="BarcodeScanner"
            phx-update="ignore"
            autoplay
            muted
            class="w-full max-w-xs rounded border border-gray-300 bg-black aspect-video"
          >
          </video>
          <p class="mt-1 text-xs text-gray-400">Point the camera at a barcode.</p>
        </div>

        <ul class="mt-3 divide-y divide-gray-100">
          <li :for={product <- @results} class="flex items-center justify-between py-2">
            <div>
              <p class="text-sm font-medium">{product.name}</p>
              <p class="text-xs text-gray-400">{product.sku} · stock {product.stock} · {format_money(product.price)}</p>
            </div>
            <.button phx-click={JS.push("add", value: %{id: product.id})} class="!py-1 !px-3 !text-sm">
              Add
            </.button>
          </li>
          <li :if={@search != "" and @results == []} class="py-2 text-sm text-gray-400">
            No in-stock products match.
          </li>
        </ul>
      </div>

      <%!-- Cart + payment --%>
      <div class="rounded-lg border border-gray-200 p-4 shadow-sm">
        <h3 class="font-semibold text-gray-700">Cart</h3>

        <p :if={@cart == []} class="mt-3 text-sm text-gray-400">Cart is empty. Add products to begin.</p>

        <table :if={@cart != []} class="w-full mt-3 text-sm">
          <tr :for={item <- @cart} class="border-t border-gray-100">
            <td class="py-2">
              <p class="font-medium">{item.name}</p>
              <p class="text-xs text-gray-400">{format_money(item.unit_price)} each</p>
            </td>
            <td class="py-2">
              <div class="flex items-center gap-2">
                <.link phx-click={JS.push("dec", value: %{id: item.product_id})} class="px-2 border rounded">-</.link>
                <span>{item.quantity}</span>
                <.link phx-click={JS.push("inc", value: %{id: item.product_id})} class="px-2 border rounded">+</.link>
              </div>
            </td>
            <td class="py-2 text-right">{format_money(Decimal.mult(item.unit_price, item.quantity))}</td>
            <td class="py-2 text-right">
              <.link phx-click={JS.push("remove", value: %{id: item.product_id})} class="text-red-600 text-xs">remove</.link>
            </td>
          </tr>
        </table>

        <form phx-change="payment" class="mt-4 space-y-2">
          <div class="grid grid-cols-2 gap-3">
            <label class="text-sm">
              Discount
              <input type="number" name="discount" value={@discount} min="0" step="0.01" class="form-control" />
            </label>
            <label class="text-sm">
              Tax
              <input type="number" name="tax" value={@tax} min="0" step="0.01" class="form-control" />
            </label>
          </div>
        </form>

        <div class="mt-3">
          <span class="text-sm">Payment method</span>
          <div class="mt-1 grid grid-cols-4 gap-2">
            <button
              :for={{value, label} <- payment_method_options()}
              type="button"
              phx-click={JS.push("set_payment_method", value: %{method: value})}
              class={[
                "text-sm py-1.5 rounded border",
                (@payment_method == value && "bg-green-700 text-white border-green-700") ||
                  "bg-white text-gray-700 border-gray-300 hover:border-green-500"
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <label :if={@payment_method == "cash"} class="block text-sm mt-2">
          Amount paid
          <input
            type="text"
            id="amount-paid"
            phx-hook="CurrencyInput"
            phx-update="ignore"
            inputmode="numeric"
            placeholder="0"
            class="form-control"
          />
        </label>
        <p :if={@payment_method != "cash"} class="text-sm text-gray-500 mt-2">
          Dibayar pas sejumlah total ({payment_method_label(@payment_method)}).
        </p>

        <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
          <.receipt_row label="Subtotal" value={format_money(@subtotal)} />
          <.receipt_row label="Total" value={format_money(@total)} bold />
          <.receipt_row :if={@payment_method == "cash"} label="Change" value={format_money(@change_due)} />
        </dl>

        <div class="mt-4">
          <.button phx-click="checkout" disabled={not @can_checkout} class="w-full">
            Complete Sale
          </.button>
        </div>
      </div>
    </div>

    <.modal :if={@last_sale} id="receipt-modal" show on_cancel={JS.push("new_sale")}>
      <h3 class="text-lg font-semibold text-center">Transaction complete</h3>
      <p class="text-center text-sm text-gray-500">Receipt {@last_sale.code}</p>

      <.sale_receipt sale={@last_sale} />

      <div class="mt-6 flex items-center justify-between gap-3">
        <.link href={~p"/sales/#{@last_sale.id}/receipt"} target="_blank" class="btn btn-sm btn-link">
          Print receipt
        </.link>
        <.button phx-click="new_sale">New Transaction</.button>
      </div>
    </.modal>

    <.modal :if={@closing and @summary} id="close-shift-modal" show on_cancel={JS.push("toggle_close")}>
      <h3 class="text-lg font-semibold">Close shift</h3>

      <dl class="mt-4 space-y-1 text-sm">
        <div class="flex justify-between"><dt>Opening cash</dt><dd>{format_money(@summary.opening_cash)}</dd></div>
        <div class="flex justify-between"><dt>Transactions</dt><dd>{@summary.transactions}</dd></div>
        <div class="flex justify-between"><dt>Cash sales</dt><dd>{format_money(@summary.cash_total)}</dd></div>
        <div class="flex justify-between text-gray-500">
          <dt>Non-cash sales (QRIS/kartu/transfer)</dt><dd>{format_money(@summary.noncash_total)}</dd>
        </div>
        <div class="flex justify-between font-semibold border-t border-gray-200 pt-1">
          <dt>Expected cash</dt>
          <dd>{format_money(@summary.expected_cash)}</dd>
        </div>
      </dl>

      <form phx-change="close_change" phx-submit="close_shift" class="mt-4 space-y-3">
        <label class="block text-sm">
          Counted cash (hitung fisik)
          <input type="number" name="counted_cash" value={@counted_cash} min="0" step="1" required class="form-control" />
        </label>

        <div class="flex justify-between text-sm font-medium">
          <span>Variance</span>
          <span class={variance_class(@counted_cash, @summary)}>
            {format_money(preview_variance(@counted_cash, @summary))}
          </span>
        </div>

        <label class="block text-sm">
          Note (optional)
          <input type="text" name="note" value={@close_note} class="form-control" />
        </label>

        <.button class="w-full !bg-red-600">Close shift</.button>
      </form>
    </.modal>
    """
  end

  defp preview_variance(counted, %{expected_cash: expected}) do
    Decimal.sub(to_dec(counted), expected)
  end

  defp preview_variance(_counted, _summary), do: Decimal.new(0)

  defp variance_class(counted, summary) do
    v = preview_variance(counted, summary)

    cond do
      Decimal.equal?(v, Decimal.new(0)) -> "text-gray-600"
      Decimal.negative?(v) -> "text-red-600"
      true -> "text-green-600"
    end
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :bold, :boolean, default: false

  defp receipt_row(assigns) do
    ~H"""
    <div class={["flex justify-between", @bold && "font-semibold"]}>
      <dt>{@label}</dt>
      <dd>{@value}</dd>
    </div>
    """
  end
end
