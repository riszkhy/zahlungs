defmodule ZahlungsWeb.CashierLive do
  @moduledoc """
  Cashier / point-of-sale screen: search products, build a cart, take payment,
  and complete a transaction (which records the sale and decrements stock).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Sales}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Cashier", last_sale: nil, scanning: false)
     |> reset_cart()}
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
      tax: socket.assigns.tax
    }

    case Sales.create_sale(socket.assigns.current_user, cart, payment) do
      {:ok, sale} ->
        {:noreply,
         socket
         |> assign(:last_sale, sale)
         |> reset_cart()
         |> put_flash(:info, "Sale #{sale.code} completed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("new_sale", _params, socket) do
    {:noreply, socket |> assign(:last_sale, nil) |> reset_cart()}
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
    |> assign(cart: [], discount: "", tax: "", amount_paid: "", search: "", results: [])
    |> assign_totals()
  end

  defp assign_totals(socket) do
    subtotal = cart_subtotal(socket.assigns.cart)
    discount = to_dec(socket.assigns.discount)
    tax = to_dec(socket.assigns.tax)
    total = subtotal |> Decimal.sub(discount) |> Decimal.add(tax)
    paid = to_dec(socket.assigns.amount_paid)
    change = Decimal.sub(paid, total)

    total_ok = not Decimal.lt?(total, Decimal.new(0))
    paid_ok = not Decimal.lt?(paid, total)

    assign(socket,
      subtotal: subtotal,
      total: total,
      change_due: change,
      can_checkout: socket.assigns.cart != [] and total_ok and paid_ok
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

  defp money(%Decimal{} = d), do: "Rp " <> Decimal.to_string(d)
  defp money(other), do: "Rp #{other}"

  defp error_message(:empty_cart), do: "Cart is empty."
  defp error_message(:insufficient_payment), do: "Amount paid is less than the total."
  defp error_message({:insufficient_stock, name}), do: "Insufficient stock for #{name}."
  defp error_message(_), do: "Could not complete the sale."

  @impl true
  def render(assigns) do
    ~H"""
    <div id="cashier-beeper" phx-hook="Beeper" class="hidden"></div>

    <.header>
      Cashier
      <:subtitle>Layar transaksi penjualan</:subtitle>
    </.header>

    <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-8">
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
              <p class="text-xs text-gray-400">{product.sku} · stock {product.stock} · {money(product.price)}</p>
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
              <p class="text-xs text-gray-400">{money(item.unit_price)} each</p>
            </td>
            <td class="py-2">
              <div class="flex items-center gap-2">
                <.link phx-click={JS.push("dec", value: %{id: item.product_id})} class="px-2 border rounded">-</.link>
                <span>{item.quantity}</span>
                <.link phx-click={JS.push("inc", value: %{id: item.product_id})} class="px-2 border rounded">+</.link>
              </div>
            </td>
            <td class="py-2 text-right">{money(Decimal.mult(item.unit_price, item.quantity))}</td>
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
          <label class="block text-sm">
            Amount paid
            <input type="number" name="amount_paid" value={@amount_paid} min="0" step="0.01" class="form-control" />
          </label>
        </form>

        <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
          <.receipt_row label="Subtotal" value={money(@subtotal)} />
          <.receipt_row label="Total" value={money(@total)} bold />
          <.receipt_row label="Change" value={money(@change_due)} />
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
    """
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
