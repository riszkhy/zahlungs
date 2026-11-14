defmodule ZahlungsWeb.CashierLive do
  @moduledoc """
  Cashier / point-of-sale screen: search products, build a cart, take payment,
  and complete a transaction (which records the sale and decrements stock).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Customers, HeldCarts, LocalTime, Promotions, Sales, Shifts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Cashier", last_sale: nil, last_sale_balance: nil, scanning: false)
     |> assign(:confirming_sale, false)
     |> assign(credit_query: "", credit_results: [])
     |> assign(:discount_limit, discount_limit(socket.assigns.current_user))
     |> assign(
       receivable_open: false,
       receivable_query: "",
       receivable_results: [],
       receivable_customer: nil,
       receivable_balance: nil,
       receivable_notes: [],
       last_payment: nil
     )
     |> assign(category_id: nil, cart_open: false, held_open: false, held: [])
     |> assign(:category_options, Zahlungs.Catalog.category_options())
     |> assign(opening_cash: "", closing: false, counted_cash: "", close_note: "", summary: nil)
     |> assign(:services_processing, 0)
     |> assign(
       movement_open: false,
       mv_category: "expense",
       mv_amount: "",
       mv_note: "",
       mv_supplier_id: "",
       movements: [],
       supplier_options: Zahlungs.Catalog.supplier_options()
     )
     |> assign_shift(Shifts.current_shift(socket.assigns.current_user))
     |> load_movements()
     |> load_held_count()
     |> subscribe_held()
     |> reset_cart()}
  end

  # Held carts come and go on the other tablets of the shift's store.
  @impl true
  def handle_info({:held_carts_changed, _store_id}, socket) do
    socket = load_held_count(socket)
    {:noreply, if(socket.assigns.held_open, do: load_held(socket), else: socket)}
  end

  defp subscribe_held(%{assigns: %{shift: %Shifts.Shift{store_id: store_id}}} = socket) do
    if connected?(socket), do: HeldCarts.subscribe(store_id)
    socket
  end

  defp subscribe_held(socket), do: socket

  # Sales are recorded in the store of the open shift, so that is the store
  # whose stock and clock this screen shows — for an admin it can differ from
  # the store picked in the navbar after the shift was opened.
  defp assign_shift(socket, shift) do
    scope = socket.assigns.current_scope

    sale_scope =
      if shift && (is_nil(scope.store) or shift.store_id != scope.store.id),
        do: %{scope | store: Zahlungs.Stores.get_store!(shift.store_id)},
        else: scope

    assign(socket,
      shift: shift,
      sale_scope: sale_scope,
      promotions: promotions(shift, sale_scope)
    )
  end

  # The promotions running today in the shift's store, applied to the cart as
  # it changes; the sale works them out again when it is recorded.
  defp reload_promotions(socket),
    do: assign(socket, :promotions, promotions(socket.assigns.shift, socket.assigns.sale_scope))

  # The cart's unit prices as the catalog has them now.
  defp refresh_cart_prices(socket) do
    ids = Enum.map(socket.assigns.cart, & &1.product_id)

    prices =
      socket.assigns.sale_scope
      |> Catalog.list_products(ids: ids)
      |> Map.new(&{&1.id, &1.price})

    socket
    |> assign(
      :cart,
      Enum.map(
        socket.assigns.cart,
        &%{&1 | unit_price: Map.get(prices, &1.product_id, &1.unit_price)}
      )
    )
    |> assign_totals()
  end

  defp promotions(nil, _sale_scope), do: []

  defp promotions(_shift, sale_scope) do
    store = sale_scope.store
    Promotions.active_for(store, LocalTime.today(store))
  end

  # An organization may limit a cashier's manual discount; admins aren't limited.
  defp discount_limit(%{role: "admin"}), do: nil
  defp discount_limit(user), do: Promotions.cashier_discount_limit(user.organization_id)

  # Re-reads the user's open shift: the one in assigns can be stale when it was
  # closed (or a new one opened) from another tab or device.
  defp refresh_shift(socket) do
    socket
    |> assign_shift(Shifts.current_shift(socket.assigns.current_user))
    |> load_movements()
    |> load_products()
    |> load_held_count()
  end

  @tile_limit 24

  # The product tiles: what can be sold right now in the open shift's store,
  # narrowed by the search box and the category chip. Empty without a shift.
  defp load_products(socket) do
    results =
      if socket.assigns.shift do
        Catalog.list_products(socket.assigns.sale_scope,
          search: socket.assigns.search,
          category_id: socket.assigns.category_id,
          active: true,
          in_stock: true,
          limit: @tile_limit
        )
      else
        []
      end

    assign(socket, :results, results)
  end

  # How many carts are held in the open shift's store (Tunda).
  defp load_held_count(socket) do
    assign(socket, :held_count, HeldCarts.count(socket.assigns.current_user))
  end

  defp load_held(socket) do
    socket
    |> assign(:held, HeldCarts.list(socket.assigns.current_user))
    |> load_held_count()
  end

  defp load_movements(socket) do
    movements =
      if socket.assigns.shift, do: Shifts.list_cash_movements(socket.assigns.shift), else: []

    assign(socket, :movements, movements)
  end

  @impl true
  def handle_event("open_shift", %{"opening_cash" => opening_cash}, socket) do
    case Shifts.open_shift(socket.assigns.current_scope, strip_money(opening_cash)) do
      {:ok, shift} ->
        {:noreply,
         socket
         |> assign_shift(shift)
         |> load_movements()
         |> load_products()
         |> load_held_count()
         |> subscribe_held()
         |> put_flash(:info, "Shift opened.")}

      {:error, :already_open} ->
        {:noreply,
         socket
         |> assign_shift(Shifts.current_shift(socket.assigns.current_user))
         |> put_flash(:error, "You already have an open shift.")}

      {:error, :no_store} ->
        {:noreply,
         put_flash(socket, :error, "Pilih satu toko di menu atas dulu untuk membuka shift.")}

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
         |> assign(closing: false, movements: [])
         |> assign_shift(nil)
         |> put_flash(:info, "Shift closed. Variance: #{format_money(closed.variance)}.")}

      {:error, :not_open} ->
        {:noreply,
         socket
         |> assign(closing: false)
         |> refresh_shift()
         |> put_flash(:error, "Shift ini sudah ditutup.")}

      {:error, :services_processing} ->
        count = Zahlungs.Services.count_blocking_close(socket.assigns.shift)

        {:noreply,
         socket
         |> assign(:services_processing, count)
         |> put_flash(:error, "Selesaikan dulu #{count} layanan yang masih diproses.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not close the shift.")}
    end
  end

  def handle_event("toggle_movement", _params, socket) do
    {:noreply,
     socket
     |> assign(:movement_open, not socket.assigns.movement_open)
     |> assign(mv_category: "expense", mv_amount: "", mv_note: "", mv_supplier_id: "")}
  end

  def handle_event("movement_change", params, socket) do
    {:noreply,
     assign(socket,
       mv_category: params["category"] || socket.assigns.mv_category,
       mv_amount: params["amount"] || "",
       mv_note: params["note"] || "",
       mv_supplier_id: params["supplier_id"] || ""
     )}
  end

  def handle_event("save_movement", params, socket) do
    attrs = %{
      "category" => params["category"],
      "amount" => strip_money(params["amount"] || ""),
      "note" => params["note"],
      "supplier_id" => blank_to_nil(params["supplier_id"])
    }

    case Shifts.add_cash_movement(socket.assigns.shift, attrs) do
      {:ok, _movement} ->
        {:noreply,
         socket
         |> assign(movement_open: false)
         |> load_movements()
         |> put_flash(:info, "Gerakan kas dicatat.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Gagal mencatat (cek jumlah & supplier).")}

      {:error, :not_open} ->
        {:noreply,
         socket
         |> assign(movement_open: false)
         |> refresh_shift()
         |> put_flash(:error, "Shift ini sudah ditutup.")}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> load_products()}
  end

  def handle_event("set_category", %{"id" => id}, socket) do
    category_id = if id in [nil, ""], do: nil, else: to_int(id)
    {:noreply, socket |> assign(:category_id, category_id) |> load_products()}
  end

  # Portrait tablets show the cart as a panel over the product tiles.
  def handle_event("toggle_cart", _params, socket) do
    {:noreply, assign(socket, :cart_open, not socket.assigns.cart_open)}
  end

  # One tap instead of typing the cash handed over: the exact total (rounded up
  # to whole rupiah) or a banknote amount. The input is owned by a JS hook, so
  # the new value is pushed to it as well.
  def handle_event("quick_cash", %{"amount" => amount}, socket) do
    value =
      case amount do
        "exact" ->
          socket.assigns.total |> Decimal.round(0, :ceiling) |> Decimal.to_integer()

        other ->
          to_int(other)
      end
      |> Integer.to_string()

    {:noreply,
     socket
     |> assign(:amount_paid, value)
     |> assign_totals()
     |> push_event("set_amount_paid_input", %{value: value})}
  end

  # Submit (Enter) — also fired by a barcode scanner after it "types" the code.
  # An exact barcode/SKU match is added to the cart and the box is cleared so the
  # next item can be scanned immediately.
  def handle_event("scan", %{"q" => code}, socket) do
    case Catalog.get_product_by_code(socket.assigns.sale_scope, code) do
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
         |> assign(:search, "")
         |> load_products()
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
     |> put_flash(
       :error,
       "Camera scanning isn't supported on this browser. Use a USB scanner or type the code."
     )}
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
      when method in ~w(cash qris card transfer credit) do
    {:noreply, socket |> assign(:payment_method, method) |> assign_totals()}
  end

  # Piutang: the customer who owes the rest of this sale.
  def handle_event("credit_search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket, credit_query: q, credit_results: find_customers(q, active_only: true))}
  end

  def handle_event("credit_pick", %{"id" => id}, socket) do
    {:noreply, socket |> pick_credit_customer(Customers.get_customer!(id)) |> assign_totals()}
  end

  def handle_event("credit_new", params, socket) do
    attrs = %{"name" => params["name"] || "", "phone" => params["phone"]}

    case Customers.create_customer(socket.assigns.current_user, attrs) do
      {:ok, customer} ->
        {:noreply,
         socket
         |> pick_credit_customer(customer)
         |> assign_totals()
         |> put_flash(:info, "Pelanggan ditambahkan. Limit piutang diatur admin.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Nama kosong atau sudah dipakai pelanggan lain.")}
    end
  end

  def handle_event("credit_clear", _params, socket) do
    {:noreply, socket |> assign(credit_customer: nil, credit_available: nil) |> assign_totals()}
  end

  def handle_event("credit_fields", params, socket) do
    {:noreply,
     socket
     |> assign(
       down_payment: strip_money(params["down_payment"] || ""),
       due_date: params["due_date"] || socket.assigns.due_date
     )
     |> assign_totals()}
  end

  # Piutang: repayments, taken on this shift whatever store the debt is from.
  def handle_event("toggle_receivable", _params, socket) do
    {:noreply,
     assign(socket,
       receivable_open: not socket.assigns.receivable_open,
       receivable_query: "",
       receivable_results: [],
       receivable_customer: nil,
       last_payment: nil
     )}
  end

  def handle_event("receivable_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, receivable_query: q, receivable_results: find_customers(q, []))}
  end

  def handle_event("receivable_pick", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(receivable_results: [], last_payment: nil)
     |> load_receivable(Customers.get_customer!(id))}
  end

  def handle_event("receive_payment", params, socket) do
    customer = socket.assigns.receivable_customer

    attrs =
      Map.take(params, ["amount", "payment_method", "note"])
      |> Map.update("amount", "", &strip_money/1)

    case Customers.receive_payment(socket.assigns.current_user, customer.id, attrs) do
      {:ok, payment} ->
        {:noreply,
         socket
         |> assign(:last_payment, payment)
         |> load_receivable(customer)
         |> put_flash(:info, "Pelunasan #{format_money(payment.amount)} diterima.")}

      {:error, :no_open_shift} ->
        {:noreply, socket |> refresh_shift() |> put_flash(:error, error_message(:no_open_shift))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Isi jumlah dan cara bayar yang benar.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
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

  # Completing a sale is two steps: the popup says what is about to be sold, and
  # only its confirmation records it.
  def handle_event("review_checkout", _params, %{assigns: %{can_checkout: true}} = socket),
    do: {:noreply, assign(socket, :confirming_sale, true)}

  def handle_event("review_checkout", _params, socket),
    do: {:noreply, put_flash(socket, :error, checkout_problem(socket.assigns))}

  def handle_event("cancel_checkout", _params, socket),
    do: {:noreply, assign(socket, :confirming_sale, false)}

  # Not confirming (any more): a second click on the way, or a stale screen.
  def handle_event("confirm_checkout", _params, %{assigns: %{confirming_sale: false}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_checkout", _params, socket) do
    socket = assign(socket, :confirming_sale, false)
    cart = Enum.map(socket.assigns.cart, &%{product_id: &1.product_id, quantity: &1.quantity})

    payment = %{
      amount_paid: socket.assigns.amount_paid,
      discount: socket.assigns.discount,
      tax: socket.assigns.tax,
      payment_method: socket.assigns.payment_method,
      expected_total: socket.assigns.total
    }

    payment =
      if socket.assigns.payment_method == "credit",
        do:
          Map.merge(payment, %{
            amount_paid: socket.assigns.down_payment,
            customer_id: socket.assigns.credit_customer && socket.assigns.credit_customer.id,
            due_date: socket.assigns.due_date
          }),
        else: payment

    case Sales.create_sale(socket.assigns.current_user, cart, payment) do
      {:ok, sale} ->
        {:noreply,
         socket
         |> assign(:last_sale, sale)
         |> assign(:last_sale_balance, sale.customer_id && Customers.balance(sale.customer_id))
         |> reset_cart()
         |> push_event("reset_amount_paid", %{})
         |> put_flash(:info, "Sale #{sale.code} completed.")}

      # The shift was closed elsewhere (e.g. another tab): show the real state.
      {:error, :no_open_shift} ->
        {:noreply, socket |> refresh_shift() |> put_flash(:error, error_message(:no_open_shift))}

      # A promotion or a price changed since the screen was priced: show the
      # new total before taking the money.
      {:error, :prices_changed} ->
        {:noreply,
         socket
         |> reload_promotions()
         |> load_products()
         |> refresh_cart_prices()
         |> put_flash(:error, error_message(:prices_changed))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Tunda: put the cart aside in the shift's store, empty the screen.
  def handle_event("hold", _params, %{assigns: %{cart: []}} = socket), do: {:noreply, socket}

  def handle_event("hold", params, socket) do
    case hold_cart(socket, params["note"]) do
      {:ok, _held} ->
        {:noreply,
         socket
         |> reset_cart()
         |> push_event("reset_amount_paid", %{})
         |> load_held()
         |> put_flash(:info, "Keranjang ditunda.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Catatan paling banyak 60 karakter.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("toggle_held", _params, socket) do
    socket = assign(socket, :held_open, not socket.assigns.held_open)
    {:noreply, if(socket.assigns.held_open, do: load_held(socket), else: socket)}
  end

  # Lanjutkan: a cart on the screen is held first, so nothing is lost.
  def handle_event("resume_held", %{"id" => id}, socket) do
    case HeldCarts.resume(socket.assigns.current_user, id, screen_cart(socket)) do
      {:ok, resumed} ->
        {:noreply,
         socket
         |> reset_cart()
         |> fill_cart(resumed)
         |> assign(:held_open, false)
         |> assign_totals()
         |> push_event("reset_amount_paid", %{})
         |> load_held()
         |> resumed_flash(resumed)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> load_held()
         |> put_flash(:error, "Sudah dilanjutkan atau dihapus di kasir lain.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("delete_held", %{"id" => id}, socket) do
    case HeldCarts.delete(socket.assigns.current_user, id) do
      :ok ->
        {:noreply, load_held(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> load_held()
         |> put_flash(:error, "Sudah dilanjutkan atau dihapus di kasir lain.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("new_sale", _params, socket) do
    {:noreply,
     socket |> assign(:last_sale, nil) |> reset_cart() |> push_event("reset_amount_paid", %{})}
  end

  ## Cart helpers

  defp add_to_cart(socket, product) do
    case Enum.find(socket.assigns.cart, &(&1.product_id == product.id)) do
      nil ->
        assign(socket, :cart, socket.assigns.cart ++ [cart_item(product, 1)])

      existing ->
        update_qty(socket, product.id, existing.quantity + 1)
    end
  end

  defp cart_item(product, quantity) do
    %{
      product_id: product.id,
      name: product.name,
      sku: product.sku,
      unit_price: product.price,
      quantity: quantity,
      stock: product.stock,
      category_id: product.category_id,
      consignment: product.consignment
    }
  end

  defp hold_cart(socket, note) do
    {items, attrs} = screen_cart(socket)
    HeldCarts.hold(socket.assigns.current_user, items, Map.put(attrs, :note, blank_to_nil(note)))
  end

  # The cart on the screen as `HeldCarts` takes it.
  defp screen_cart(socket) do
    items = Enum.map(socket.assigns.cart, &%{product_id: &1.product_id, quantity: &1.quantity})
    {items, %{discount: to_dec(socket.assigns.discount), tax: to_dec(socket.assigns.tax)}}
  end

  # A cart that comes back empty brings no discount or tax to the next customer.
  defp fill_cart(socket, %{items: []}), do: socket

  defp fill_cart(socket, resumed) do
    assign(socket,
      cart: Enum.map(resumed.items, &cart_item(&1.product, &1.quantity)),
      discount: amount_field(resumed.discount),
      tax: amount_field(resumed.tax)
    )
  end

  defp resumed_flash(socket, %{items: []}),
    do: put_flash(socket, :info, "Keranjang kembali kosong: barangnya sudah tidak dijual.")

  defp resumed_flash(socket, %{adjusted: adjusted}) when adjusted > 0,
    do: put_flash(socket, :info, "#{adjusted} barang disesuaikan dengan stok.")

  defp resumed_flash(socket, _resumed), do: socket

  # A held amount back in its field: empty for none, as the cashier left it.
  defp amount_field(amount) do
    if Decimal.equal?(amount, 0),
      do: "",
      else: amount |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  # A held cart's label in the list: its note, or what it holds.
  defp held_label(%{note: note}, _store) when is_binary(note) and note != "", do: note

  defp held_label(held, store) do
    time = held.inserted_at |> LocalTime.to_local(store) |> Calendar.strftime("%H:%M")
    "#{held.units} item · #{format_money(held.total)} · #{time}"
  end

  @doc "How long ago a cart was held, for the list: \"5 menit lalu\"."
  def held_age(inserted_at, now \\ NaiveDateTime.utc_now()) do
    seconds = NaiveDateTime.diff(now, inserted_at)

    cond do
      seconds < 60 -> "baru saja"
      seconds < 3600 -> "#{div(seconds, 60)} menit lalu"
      seconds < 86_400 -> "#{div(seconds, 3600)} jam lalu"
      true -> "#{div(seconds, 86_400)} hari lalu"
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
    |> assign(
      cart: [],
      discount: "",
      tax: "",
      amount_paid: "",
      payment_method: "cash",
      search: "",
      credit_customer: nil,
      credit_available: nil,
      down_payment: "",
      due_date: default_due_date(socket)
    )
    |> reload_promotions()
    |> assign_totals()
    |> load_products()
  end

  # A credit note is due in 30 days unless the cashier changes it, counted in
  # the open shift's store.
  defp default_due_date(socket) do
    socket.assigns.sale_scope.store
    |> LocalTime.today()
    |> Date.add(30)
    |> Date.to_iso8601()
  end

  defp find_customers(q, opts) do
    if String.trim(q) == "",
      do: [],
      else: q |> then(&Customers.list_customers([q: &1] ++ opts)) |> Enum.take(8)
  end

  defp pick_credit_customer(socket, customer) do
    assign(socket,
      credit_customer: customer,
      credit_available: Customers.available_credit(customer),
      credit_query: "",
      credit_results: []
    )
  end

  defp load_receivable(socket, customer) do
    balance = Customers.balance(customer)

    assign(socket,
      receivable_customer: customer,
      receivable_balance: balance,
      receivable_notes: Customers.open_notes(customer)
    )
  end

  @banknotes [5_000, 10_000, 20_000, 50_000, 100_000]

  # Banknote amounts that would cover the total, for the quick-cash buttons.
  defp quick_amounts(total) do
    Enum.filter(@banknotes, &(not Decimal.lt?(Decimal.new(&1), total)))
  end

  defp cart_units(cart), do: Enum.reduce(cart, 0, &(&1.quantity + &2))

  defp assign_totals(socket) do
    priced = price_cart(socket.assigns.cart, socket.assigns[:promotions] || [])
    subtotal = cart_subtotal(priced)
    discount = to_dec(socket.assigns.discount)
    tax = to_dec(socket.assigns.tax)
    total = subtotal |> Decimal.sub(discount) |> Decimal.add(tax)
    {change, paid_ok} = tendered(socket.assigns, total)

    amount_error = amount_error(subtotal, discount, tax, socket.assigns[:discount_limit])
    credit? = socket.assigns.payment_method == "credit"
    credit_error = if credit?, do: credit_error(socket.assigns, total)

    assign(socket,
      priced_cart: priced,
      promo_saving: Enum.reduce(priced, Decimal.new(0), &Decimal.add(&2, &1.discount)),
      subtotal: subtotal,
      total: total,
      change_due: change,
      amount_error: amount_error,
      credit_error: credit_error,
      can_checkout:
        socket.assigns[:shift] != nil and socket.assigns.cart != [] and is_nil(amount_error) and
          paid_ok and credit_ok?(credit?, socket.assigns.credit_customer, credit_error)
    )
  end

  # Cash must cover the total and may leave change. Non-cash is settled for the
  # exact total: no tendered amount, no change.
  defp tendered(%{payment_method: "cash", amount_paid: amount_paid}, total) do
    paid = to_dec(amount_paid)
    {Decimal.sub(paid, total), not Decimal.lt?(paid, total)}
  end

  defp tendered(_assigns, _total), do: {Decimal.new(0), true}

  # Why a sale that can_checkout refuses can't be completed: the button is off
  # then, so this answers a stale screen.
  defp checkout_problem(assigns) do
    cond do
      assigns.amount_error -> assigns.amount_error
      assigns.credit_error -> assigns.credit_error
      is_nil(assigns[:shift]) -> error_message(:no_open_shift)
      assigns.cart == [] -> error_message(:empty_cart)
      assigns.payment_method == "credit" -> error_message(:customer_required)
      true -> error_message(:insufficient_payment)
    end
  end

  defp credit_ok?(false, _customer, _error), do: true
  defp credit_ok?(true, customer, error), do: customer != nil and is_nil(error)

  # Same rules Sales.create_sale/3 and Customers.lock_for_credit/2 enforce for
  # a credit sale; shown inline so the cashier knows why it can't be completed.
  defp credit_error(%{credit_customer: nil}, _total), do: nil

  defp credit_error(assigns, total) do
    down_payment = to_dec(assigns.down_payment)
    debt = Decimal.sub(total, down_payment)

    cond do
      not assigns.credit_customer.active ->
        "Pelanggan nonaktif."

      Decimal.negative?(down_payment) or not Decimal.lt?(down_payment, total) ->
        error_message(:down_payment_too_high)

      Decimal.gt?(debt, assigns.credit_available) ->
        "Melebihi limit piutang #{format_money(Decimal.max(assigns.credit_available, 0))}."

      true ->
        nil
    end
  end

  # Same rules Sales.create_sale/3 enforces; shown inline so the cashier knows
  # why Complete Sale is disabled.
  defp amount_error(subtotal, discount, tax, limit) do
    cond do
      Decimal.negative?(discount) -> "Diskon tidak boleh negatif."
      Decimal.gt?(discount, subtotal) -> "Diskon tidak boleh melebihi subtotal."
      over_limit?(discount, subtotal, limit) -> limit_message(limit)
      Decimal.negative?(tax) -> "Pajak tidak boleh negatif."
      true -> nil
    end
  end

  defp over_limit?(_discount, _subtotal, nil), do: false

  defp over_limit?(discount, subtotal, limit),
    do: Decimal.gt?(discount, subtotal |> Decimal.mult(limit) |> Decimal.div(100))

  defp limit_message(limit),
    do:
      "Diskon maksimal #{limit |> Decimal.normalize() |> Decimal.to_string(:normal)}% dari subtotal."

  # Each cart line with its promotion (discount, name) and net line total.
  defp price_cart(cart, promotions) do
    cart
    |> Enum.map(
      &Map.put(&1, :product, %{
        id: &1.product_id,
        category_id: &1[:category_id],
        consignment: &1[:consignment] || false
      })
    )
    |> Promotions.apply(promotions)
    |> Enum.map(
      &Map.put(
        &1,
        :line_total,
        Decimal.sub(Decimal.mult(&1.unit_price, &1.quantity), &1.discount)
      )
    )
  end

  defp cart_subtotal(priced),
    do: Enum.reduce(priced, Decimal.new(0), &Decimal.add(&2, &1.line_total))

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
  defp error_message(:invalid_discount), do: "Diskon harus antara 0 dan subtotal."
  defp error_message(:invalid_tax), do: "Pajak tidak boleh negatif."
  defp error_message(:no_open_shift), do: "Shift belum dibuka atau sudah ditutup."
  defp error_message({:insufficient_stock, name}), do: "Insufficient stock for #{name}."
  defp error_message(:over_credit_limit), do: "Melebihi limit piutang pelanggan."
  defp error_message(:customer_inactive), do: "Pelanggan nonaktif."
  defp error_message(:customer_required), do: "Pilih pelanggan dulu."

  defp error_message(:down_payment_too_high),
    do: "Uang muka harus kurang dari total; pakai bayar tunai."

  defp error_message(:invalid_due_date), do: "Jatuh tempo tidak boleh sebelum hari ini."
  defp error_message(:over_balance), do: "Melebihi sisa utang."
  defp error_message(:discount_over_limit), do: "Diskon melebihi batas yang diatur admin."

  defp error_message(:prices_changed),
    do: "Harga atau promo berubah. Cek total baru, lalu bayar lagi."

  defp error_message(:not_found), do: "Pelanggan tidak ditemukan."
  defp error_message(_), do: "Could not complete the sale."

  # The MoneyInput hook submits a thousands-formatted string (e.g. "100.000");
  # strip the separators so it parses as integer Rupiah on the server.
  defp strip_money(value) when is_binary(value), do: String.replace(value, ~r/\D/, "")
  defp strip_money(value), do: value

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp movement_category_options do
    [
      {"expense", "Pengeluaran (beli keperluan)"},
      {"cash_drop", "Setor ke brankas"},
      {"cash_in", "Uang masuk / tambah modal"},
      {"consignment_payment", "Bayar konsinyasi"}
    ]
  end

  # Refunds are booked by Sales.return_sale/2 and Customers.refund_overpayment/3,
  # so they are not in the options above.
  defp movement_label("refund"), do: "Refund retur"
  defp movement_label("customer_refund"), do: "Kembalikan kelebihan"

  defp movement_label(category) do
    movement_category_options()
    |> List.keyfind(category, 0)
    |> case do
      {_value, label} -> label
      nil -> category
    end
  end

  defp movement_sign("in"), do: "+"
  defp movement_sign(_), do: "−"

  defp payment_method_options do
    [
      {"cash", "Tunai"},
      {"qris", "QRIS"},
      {"card", "Kartu"},
      {"transfer", "Transfer"},
      {"credit", "Piutang"}
    ]
  end

  # Sales take cash or credit only (QRIS/Kartu/Transfer are switched off at the
  # cashier); repayments may come in any of the four.
  defp sale_method?(method), do: method in ~w(cash credit)

  defp repayment_method_options,
    do: Enum.reject(payment_method_options(), &(elem(&1, 0) == "credit"))

  defp payment_method_label(method) do
    payment_method_options()
    |> List.keyfind(method, 0)
    |> case do
      {_value, label} -> label
      nil -> method
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="cashier-beeper" phx-hook="Beeper" class="hidden"></div>

    <div class="md3 -m-6 rounded-xl bg-surface p-4 text-on-surface sm:p-6">
      <.header>
        Cashier
        <:subtitle>Layar transaksi penjualan</:subtitle>
      </.header>

      <.md_card :if={is_nil(@shift)} variant="outlined" class="mt-6 max-w-sm p-6">
        <h3 class="text-title-lg">Open shift</h3>
        <p class="mt-1 text-body-md text-on-surface-variant">
          You must open a shift (enter the opening cash) before making sales.
        </p>
        <p :if={@current_scope.store} class="mt-1 text-body-md">
          Toko: <strong>{@current_scope.store.name}</strong>
        </p>
        <p :if={is_nil(@current_scope.store)} class="mt-1 text-body-md text-warning">
          Pilih satu toko di menu atas dulu — shift dibuka untuk satu toko.
        </p>
        <form phx-submit="open_shift" class="mt-4">
          <.md_text_field
            id="opening-cash-input"
            name="opening_cash"
            value={@opening_cash}
            label="Opening cash (modal awal)"
            phx-hook="MoneyInput"
            phx-update="ignore"
            inputmode="numeric"
            placeholder="0"
            required
          />
          <.md_button class="mt-4 w-full">Open shift</.md_button>
        </form>
      </.md_card>

      <div
        :if={@shift}
        class="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-md3-md bg-surface-container-low p-3"
      >
        <div class="min-w-0">
          <p :if={@sale_scope.store} class="text-title-sm">{@sale_scope.store.name}</p>
          <p class="text-body-sm text-on-surface-variant">
            Shift #{@shift.id} · opened {Calendar.strftime(Zahlungs.LocalTime.to_local(@shift.opened_at, @sale_scope.store), "%d %b %Y %H:%M")} · float {format_money(@shift.opening_cash)}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.md_button variant="outlined" type="button" phx-click="toggle_movement">Catat kas</.md_button>
          <.md_button variant="outlined" type="button" phx-click="toggle_close" class="!text-error">
            Close shift
          </.md_button>
        </div>
      </div>

      <.md_card :if={@shift && @movements != []} variant="outlined" class="mt-2 p-3 text-body-md">
        <p class="text-title-sm">Gerakan kas shift ini</p>
        <ul class="mt-1 divide-y divide-outline-variant">
          <li :for={m <- @movements} class="flex justify-between py-1">
            <span class="text-on-surface-variant">
              {movement_label(m.category)}
              <span :if={m.supplier}>· {m.supplier.name}</span>
              <span :if={m.note not in [nil, ""]}>· {m.note}</span>
            </span>
            <span class={if m.direction == "in", do: "text-primary", else: "text-error"}>
              {movement_sign(m.direction)}{format_money(m.amount)}
            </span>
          </li>
        </ul>
      </.md_card>

      <%!--
        Two panels side by side on a landscape tablet or wider (products left, cart
        right). On a portrait tablet or phone the products fill the screen and the
        cart is a bottom sheet opened from the bar pinned to the bottom.
      --%>
      <div :if={@shift} class="mt-4 grid grid-cols-1 gap-6 lg:grid-cols-5 md:landscape:grid-cols-5">
        <%!-- Product search + tiles --%>
        <div class="pb-24 lg:col-span-3 lg:pb-0 md:landscape:col-span-3 md:landscape:pb-0">
          <form phx-change="search" phx-submit="scan">
            <.md_search
              id="cashier-search"
              name="q"
              value={@search}
              placeholder="Scan barcode or search name / SKU"
              phx-debounce="200"
              autocomplete="off"
            >
              <:trailing>
                <button
                  type="button"
                  phx-click="toggle_camera"
                  aria-label={if @scanning, do: "Stop camera", else: "Scan with camera"}
                  class="md-state -mr-2 flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-on-surface-variant"
                >
                  <.md_icon name={if @scanning, do: "close", else: "camera"} />
                </button>
              </:trailing>
            </.md_search>
            <p class="mt-1 px-4 text-body-sm text-on-surface-variant">
              Tip: a barcode scanner types the code and presses Enter to add the item.
            </p>
          </form>

          <div :if={@scanning} class="mt-2">
            <video
              id="cashier-scanner"
              phx-hook="BarcodeScanner"
              phx-update="ignore"
              autoplay
              muted
              class="aspect-video w-full max-w-xs rounded-md3-md bg-black"
            >
            </video>
            <p class="mt-1 text-body-sm text-on-surface-variant">Point the camera at a barcode.</p>
          </div>

          <div class="mt-3 flex flex-wrap gap-2">
            <%!-- Piutang: a customer repays (part of) what they owe, into this shift. --%>
            <.md_chip phx-click="toggle_receivable" selected={@receivable_open}>
              <:icon :if={not @receivable_open}><.md_icon name="person" class="-ml-1 h-[18px] w-[18px]" /></:icon>
              Piutang
            </.md_chip>
            <%!-- Carts put aside in this store (Tunda), to resume from any tablet. --%>
            <.md_chip :if={@held_count > 0} phx-click="toggle_held" selected={@held_open}>
              <:icon :if={not @held_open}><.md_icon name="history" class="-ml-1 h-[18px] w-[18px]" /></:icon>
              Ditunda ({@held_count})
            </.md_chip>
          </div>

          <.md_card :if={@receivable_open} id="receivable-panel" variant="outlined" class="mt-2 p-3 text-body-md">
            <form phx-change="receivable_search" phx-submit="receivable_search">
              <.md_text_field
                type="search"
                name="q"
                value={@receivable_query}
                placeholder="Cari pelanggan (nama / no HP)"
                phx-debounce="250"
                autocomplete="off"
              />
            </form>
            <div
              :if={@receivable_results != []}
              class="mt-1 divide-y divide-outline-variant rounded-md3-xs border border-outline-variant"
            >
              <button
                :for={c <- @receivable_results}
                type="button"
                phx-click={JS.push("receivable_pick", value: %{id: c.id})}
                class="md-state block w-full px-3 py-2 text-left"
              >
                {c.name} <span class="text-body-sm text-on-surface-variant">{c.phone}</span>
              </button>
            </div>

            <div :if={@receivable_customer} class="mt-3">
              <div class="flex items-baseline justify-between">
                <p class="text-title-sm">{@receivable_customer.name}</p>
                <p>
                  {if Decimal.negative?(@receivable_balance), do: "Lebih bayar", else: "Sisa utang"}
                  <span class="font-medium">{format_money(Decimal.abs(@receivable_balance))}</span>
                </p>
              </div>
              <ul :if={@receivable_notes != []} class="mt-2 space-y-1 text-body-sm">
                <li :for={note <- @receivable_notes} class="flex justify-between">
                  <span>
                    {note.sale.code} · jatuh tempo {note.sale.due_date && Calendar.strftime(note.sale.due_date, "%d/%m/%Y")}
                  </span>
                  <span class={note.overdue? && "font-medium text-error"}>
                    {format_money(note.remaining)}{if note.overdue?, do: " · lewat"}
                  </span>
                </li>
              </ul>
              <form
                :if={Decimal.gt?(@receivable_balance, 0)}
                id="receive-payment-form"
                phx-submit="receive_payment"
                class="mt-3 grid grid-cols-2 gap-2"
              >
                <.md_text_field
                  name="amount"
                  label="Jumlah"
                  inputmode="numeric"
                  value={Decimal.to_string(Decimal.round(@receivable_balance, 0, :down), :normal)}
                />
                <.md_text_field
                  type="select"
                  name="payment_method"
                  label="Cara bayar"
                  options={Enum.map(repayment_method_options(), fn {value, label} -> {label, value} end)}
                />
                <div class="col-span-2">
                  <.md_text_field name="note" maxlength="255" placeholder="Catatan (opsional)" />
                </div>
                <.md_button class="col-span-2">Terima pelunasan</.md_button>
              </form>
              <p :if={@last_payment} class="mt-2 text-body-sm">
                <.link
                  href={~p"/customer_payments/#{@last_payment.id}/receipt"}
                  target="_blank"
                  class="text-primary hover:underline"
                >
                  Cetak struk pelunasan
                </.link>
              </p>
            </div>
          </.md_card>

          <.md_card
            :if={@held_count > 0 and @held_open}
            id="held-carts"
            variant="outlined"
            class="mt-2 divide-y divide-outline-variant p-0"
          >
            <div :for={held <- @held} id={"held-#{held.id}"} class="flex items-center justify-between gap-2 p-3 text-body-md">
              <div class="min-w-0">
                <p class="truncate text-title-sm">{held_label(held, @sale_scope.store)}</p>
                <p class="text-body-sm text-on-surface-variant">{held_age(held.inserted_at)}</p>
              </div>
              <div class="flex shrink-0 gap-2">
                <.md_button variant="tonal" type="button" phx-click={JS.push("resume_held", value: %{id: held.id})}>
                  Lanjutkan
                </.md_button>
                <.md_button
                  variant="text"
                  type="button"
                  phx-click={JS.push("delete_held", value: %{id: held.id})}
                  data-confirm="Hapus keranjang tertunda ini?"
                  class="!text-error"
                >
                  Hapus
                </.md_button>
              </div>
            </div>
          </.md_card>

          <div class="mt-3 flex gap-2 overflow-x-auto pb-1 [scrollbar-width:none]" role="group" aria-label="Kategori">
            <.md_chip phx-click={JS.push("set_category", value: %{id: ""})} selected={is_nil(@category_id)}>
              Semua
            </.md_chip>
            <.md_chip
              :for={{name, id} <- @category_options}
              phx-click={JS.push("set_category", value: %{id: id})}
              selected={@category_id == id}
            >
              {name}
            </.md_chip>
          </div>

          <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3">
            <button
              :for={product <- @results}
              type="button"
              phx-click={JS.push("add", value: %{id: product.id})}
              class="md-state min-h-[88px] rounded-md3-md bg-surface-container-low p-3 text-left"
            >
              <span class="block text-title-sm line-clamp-2">{product.name}</span>
              <span class="mt-1 block text-label-lg text-primary">{format_money(product.price)}</span>
              <span class="mt-1 block text-body-sm text-on-surface-variant">Stok {product.stock}</span>
            </button>
          </div>
          <p :if={@results == []} class="mt-3 text-body-md text-on-surface-variant">
            Tidak ada produk berstok yang cocok.
          </p>
        </div>

        <%!-- Cart + payment: a panel on wide screens, a bottom sheet on phones. --%>
        <.md_sheet id="cart-sheet" open={@cart_open} on_close="toggle_cart" class="lg:col-span-2 md:landscape:col-span-2">
          <div class="rounded-md3-lg bg-surface-container-lowest p-4 lg:sticky lg:top-20 lg:max-h-[calc(100vh-6rem)] lg:overflow-y-auto md:landscape:sticky md:landscape:top-20 md:landscape:max-h-[calc(100vh-6rem)] md:landscape:overflow-y-auto">
            <div class="flex items-center justify-between">
              <h3 class="text-title-md">Cart</h3>
              <.md_button variant="text" type="button" phx-click="toggle_cart" class="lg:hidden md:landscape:hidden">
                Tutup
              </.md_button>
            </div>

            <p :if={@cart == []} class="mt-3 text-body-md text-on-surface-variant">
              Cart is empty. Add products to begin.
            </p>

            <table :if={@cart != []} class="mt-3 w-full text-body-md">
              <tr :for={item <- @priced_cart} class="border-t border-outline-variant">
                <td class="py-2">
                  <p class="text-body-lg">{item.name}</p>
                  <p class="text-body-sm text-on-surface-variant">{format_money(item.unit_price)} each</p>
                  <p :if={item.promotion_name} class="text-body-sm text-warning">
                    {item.promotion_name} −{format_money(item.discount)}
                  </p>
                </td>
                <td class="py-2">
                  <div class="flex items-center gap-2">
                    <.md_button
                      variant="outlined"
                      type="button"
                      phx-click={JS.push("dec", value: %{id: item.product_id})}
                      aria-label="Kurangi"
                      class="!h-11 !w-11 !px-0"
                    >
                      <.md_icon name="minus" />
                    </.md_button>
                    <span class="min-w-[1.5rem] text-center text-title-sm">{item.quantity}</span>
                    <.md_button
                      variant="tonal"
                      type="button"
                      phx-click={JS.push("inc", value: %{id: item.product_id})}
                      aria-label="Tambah"
                      class="!h-11 !w-11 !px-0"
                    >
                      <.md_icon name="plus" />
                    </.md_button>
                  </div>
                </td>
                <td class="py-2 text-right">
                  <span :if={item.promotion_name} class="block text-body-sm text-on-surface-variant line-through">
                    {format_money(Decimal.mult(item.unit_price, item.quantity))}
                  </span>
                  {format_money(item.line_total)}
                </td>
                <td class="py-2 text-right">
                  <.link
                    phx-click={JS.push("remove", value: %{id: item.product_id})}
                    class="text-label-md text-error"
                  >
                    remove
                  </.link>
                </td>
              </tr>
            </table>

            <form phx-change="payment" class="mt-4 space-y-2">
              <div class="grid grid-cols-2 gap-3">
                <.md_text_field type="number" name="discount" value={@discount} min="0" step="0.01" label="Discount" />
                <.md_text_field type="number" name="tax" value={@tax} min="0" step="0.01" label="Tax" />
              </div>
              <p :if={@amount_error && @cart != []} class="text-body-md text-error">{@amount_error}</p>
            </form>

            <div class="mt-3">
              <span class="text-body-sm text-on-surface-variant">Payment method</span>
              <.md_segmented
                name="payment_method"
                value={@payment_method}
                options={payment_method_options()}
                disabled_options={for {value, _} <- payment_method_options(), not sale_method?(value), do: value}
                event="set_payment_method"
                value_key={:method}
                class="mt-1"
              />
            </div>

            <div :if={@payment_method == "cash"} class="mt-3">
              <.md_text_field
                id="amount-paid"
                label="Amount paid"
                phx-hook="CurrencyInput"
                phx-update="ignore"
                inputmode="numeric"
                placeholder="0"
              />
            </div>
            <div
              :if={@payment_method == "cash" and @cart != []}
              class="mt-2 flex flex-wrap gap-2"
              role="group"
              aria-label="Nominal cepat"
            >
              <.md_chip kind="assist" phx-click={JS.push("quick_cash", value: %{amount: "exact"})}>
                Uang pas
              </.md_chip>
              <.md_chip
                :for={amount <- quick_amounts(@total)}
                kind="assist"
                data-quick-cash={amount}
                phx-click={JS.push("quick_cash", value: %{amount: amount})}
              >
                {format_money(amount)}
              </.md_chip>
            </div>
            <p :if={@payment_method not in ["cash", "credit"]} class="mt-2 text-body-md text-on-surface-variant">
              Dibayar pas sejumlah total ({payment_method_label(@payment_method)}).
            </p>

            <%!-- Piutang: who owes the rest, how much is paid now, and when the rest is due. --%>
            <div
              :if={@payment_method == "credit"}
              id="credit-panel"
              class="mt-3 rounded-md3-md bg-warning-container p-3 text-body-md text-on-warning-container"
            >
              <%= if @credit_customer do %>
                <div class="flex items-start justify-between gap-2">
                  <div>
                    <p class="text-title-sm">{@credit_customer.name}</p>
                    <p class="text-body-sm">
                      Utang {format_money(Decimal.sub(@credit_customer.credit_limit, @credit_available))} · Limit {format_money(@credit_customer.credit_limit)} · Sisa limit {format_money(Decimal.max(@credit_available, 0))}
                    </p>
                  </div>
                  <.md_button variant="text" type="button" phx-click="credit_clear">Ganti</.md_button>
                </div>
                <form phx-change="credit_fields" class="mt-2 grid grid-cols-2 gap-2">
                  <.md_text_field
                    name="down_payment"
                    value={@down_payment}
                    label="Uang muka (tunai)"
                    inputmode="numeric"
                    placeholder="0"
                  />
                  <.md_text_field type="date" name="due_date" value={@due_date} label="Jatuh tempo" />
                </form>
                <p :if={@credit_customer && Decimal.equal?(@credit_customer.credit_limit, 0)} class="mt-1 text-body-sm">
                  Limit piutang diatur admin.
                </p>
              <% else %>
                <form phx-change="credit_search" phx-submit="credit_search">
                  <.md_text_field
                    type="search"
                    name="q"
                    value={@credit_query}
                    placeholder="Cari pelanggan (nama / no HP)"
                    phx-debounce="250"
                    autocomplete="off"
                  />
                </form>
                <div
                  :if={@credit_results != []}
                  class="mt-1 divide-y divide-outline-variant rounded-md3-xs border border-outline-variant bg-surface-container-lowest"
                >
                  <button
                    :for={c <- @credit_results}
                    type="button"
                    phx-click={JS.push("credit_pick", value: %{id: c.id})}
                    class="md-state block w-full px-3 py-2 text-left text-on-surface"
                  >
                    {c.name} <span class="text-body-sm text-on-surface-variant">{c.phone}</span>
                  </button>
                </div>
                <form phx-submit="credit_new" class="mt-2 flex flex-wrap items-end gap-2">
                  <div class="min-w-0 flex-1">
                    <.md_text_field name="name" maxlength="80" placeholder="Nama pelanggan baru" />
                  </div>
                  <div class="w-28">
                    <.md_text_field name="phone" maxlength="20" placeholder="No HP" inputmode="tel" />
                  </div>
                  <.md_button variant="text" type="submit">+ Pelanggan baru</.md_button>
                </form>
              <% end %>
              <p :if={@credit_error && @cart != []} class="mt-2 text-body-md text-error">{@credit_error}</p>
            </div>

            <dl class="mt-4 space-y-1 border-t border-outline-variant pt-3 text-body-md">
              <.receipt_row
                :if={Decimal.gt?(@promo_saving, 0)}
                label="Hemat promo"
                value={"−" <> format_money(@promo_saving)}
              />
              <.receipt_row label="Subtotal" value={format_money(@subtotal)} />
              <.receipt_row label="Total" value={format_money(@total)} bold />
              <.receipt_row :if={@payment_method == "cash"} label="Change" value={format_money(@change_due)} />
              <.receipt_row
                :if={@payment_method == "credit"}
                label="Jadi utang"
                value={format_money(Decimal.max(Decimal.sub(@total, to_dec(@down_payment)), 0))}
              />
            </dl>

            <div class="mt-4">
              <.md_button type="button" phx-click="review_checkout" disabled={not @can_checkout} class="!h-14 w-full">
                Complete sale
              </.md_button>
            </div>

            <%!-- Tunda: put the cart aside to serve the next customer. --%>
            <form :if={@cart != []} id="hold-form" phx-submit="hold" class="mt-3 flex items-end gap-2">
              <div class="min-w-0 flex-1">
                <.md_text_field name="note" maxlength="60" placeholder="Catatan (opsional)" autocomplete="off" />
              </div>
              <.md_button variant="outlined" type="submit">Tunda</.md_button>
            </form>
          </div>
        </.md_sheet>

        <%!-- Phones and portrait tablets: the cart at a glance, pinned to the bottom. --%>
        <div class="cart-bar !min-h-[80px] !border-t-0 !bg-surface-container shadow-elev-2 lg:hidden md:landscape:hidden">
          <div class="min-w-0 flex-1">
            <p class="text-body-sm text-on-surface-variant">{cart_units(@cart)} item</p>
            <p class="truncate text-title-lg">{format_money(@total)}</p>
          </div>
          <.md_button type="button" phx-click="toggle_cart" disabled={@cart == []}>
            {if @cart_open, do: "Tutup", else: "Bayar"}
          </.md_button>
        </div>
      </div>
    </div>

    <.md_dialog :if={@confirming_sale} id="confirm-sale" show on_cancel={JS.push("cancel_checkout")}>
      <:title>Konfirmasi penjualan</:title>
      <p class="mt-1 text-body-md text-on-surface-variant">Periksa barang dan pembayaran sebelum melanjutkan.</p>

      <div class="mt-3 max-h-60 overflow-y-auto">
        <table class="w-full text-body-md">
          <tr :for={item <- @priced_cart} class="border-t border-outline-variant">
            <td class="py-2">
              <p class="font-medium">{item.name}</p>
              <p class="text-body-sm text-on-surface-variant">{item.quantity} × {format_money(item.unit_price)}</p>
              <p :if={item.promotion_name} class="text-body-sm text-warning">
                {item.promotion_name} −{format_money(item.discount)}
              </p>
            </td>
            <td class="py-2 text-right">{format_money(item.line_total)}</td>
          </tr>
        </table>
      </div>

      <dl class="mt-3 space-y-1 border-t border-outline-variant pt-3 text-body-md">
        <.receipt_row
          :if={Decimal.gt?(@promo_saving, 0)}
          label="Hemat promo"
          value={"−" <> format_money(@promo_saving)}
        />
        <.receipt_row label="Subtotal" value={format_money(@subtotal)} />
        <.receipt_row :if={Decimal.gt?(to_dec(@discount), 0)} label="Diskon" value={"−" <> format_money(to_dec(@discount))} />
        <.receipt_row :if={Decimal.gt?(to_dec(@tax), 0)} label="Pajak" value={format_money(to_dec(@tax))} />
        <.receipt_row label="Total" value={format_money(@total)} bold />
        <.receipt_row label="Cara bayar" value={payment_method_label(@payment_method)} />
        <.receipt_row :if={@payment_method == "cash"} label="Uang diterima" value={format_money(to_dec(@amount_paid))} />
        <.receipt_row :if={@payment_method == "cash"} label="Kembalian" value={format_money(@change_due)} />
        <%= if @payment_method == "credit" and @credit_customer do %>
          <.receipt_row label="Pelanggan" value={@credit_customer.name} />
          <.receipt_row label="Uang muka" value={format_money(to_dec(@down_payment))} />
          <.receipt_row
            label="Jadi utang"
            value={format_money(Decimal.max(Decimal.sub(@total, to_dec(@down_payment)), 0))}
            bold
          />
          <.receipt_row label="Jatuh tempo" value={@due_date} />
        <% end %>
      </dl>

      <%!-- Batal comes first: the popup focuses it, so a scanner's Enter sells nothing. --%>
      <:actions>
        <.md_button variant="text" type="button" phx-click="cancel_checkout">Batal</.md_button>
        <.md_button type="button" phx-click="confirm_checkout" phx-disable-with="Menyimpan...">
          Ya, selesaikan
        </.md_button>
      </:actions>
    </.md_dialog>

    <.md_dialog :if={@last_sale} id="receipt-modal" show on_cancel={JS.push("new_sale")}>
      <:title>Transaction complete</:title>
      <p class="text-body-md text-on-surface-variant">Receipt {@last_sale.code}</p>

      <.sale_receipt sale={@last_sale} customer_balance={@last_sale_balance} />

      <:actions>
        <.link
          href={~p"/sales/#{@last_sale.id}/receipt"}
          target="_blank"
          class="md-state inline-flex h-10 items-center rounded-full px-3 text-label-lg text-primary"
        >
          Print receipt
        </.link>
        <.link
          navigate={~p"/sales/#{@last_sale.id}"}
          class="md-state inline-flex h-10 items-center rounded-full px-3 text-label-lg text-warning"
        >
          Koreksi / batalkan
        </.link>
        <.md_button type="button" phx-click="new_sale">New Transaction</.md_button>
      </:actions>
    </.md_dialog>

    <.md_dialog :if={@closing and @summary} id="close-shift-modal" show on_cancel={JS.push("toggle_close")}>
      <:title>Close shift</:title>

      <p
        :if={@services_processing > 0}
        class="mt-3 rounded-md3-md bg-warning-container p-3 text-body-md text-on-warning-container"
      >
        Masih ada {@services_processing} layanan berstatus diproses. Tandai hasilnya dulu di
        <.link navigate={~p"/services"} class="font-medium underline">Layanan</.link>.
      </p>

      <p :if={@held_count > 0} class="mt-3 rounded-md3-md bg-warning-container p-3 text-body-md text-on-warning-container">
        Ada {@held_count} keranjang tertunda di toko ini. Keranjang tetap tersimpan.
      </p>

      <.md_card class="mt-4 !bg-surface-container-highest">
        <dl class="space-y-1 text-body-md">
          <div class="flex justify-between"><dt>Opening cash</dt><dd>{format_money(@summary.opening_cash)}</dd></div>
          <div class="flex justify-between"><dt>Transactions</dt><dd>{@summary.transactions}</dd></div>
          <div class="flex justify-between"><dt>Cash sales</dt><dd>{format_money(@summary.cash_total)}</dd></div>
          <div :if={@summary.service_count > 0} class="flex justify-between">
            <dt>Layanan tunai</dt>
            <dd>{format_money(@summary.service_cash_total)}</dd>
          </div>
          <div class="flex justify-between text-on-surface-variant">
            <dt>Non-cash sales (QRIS/kartu/transfer)</dt><dd>{format_money(@summary.noncash_total)}</dd>
          </div>
          <div :if={Decimal.gt?(@summary.credit_total, 0)} class="flex justify-between">
            <dt>Penjualan piutang (uang muka tunai {format_money(@summary.credit_down_payment)})</dt>
            <dd>{format_money(@summary.credit_total)}</dd>
          </div>
          <div
            :if={Decimal.gt?(Decimal.add(@summary.payments_cash, @summary.payments_noncash), 0)}
            class="flex justify-between"
          >
            <dt>Pelunasan piutang (non-tunai {format_money(@summary.payments_noncash)})</dt>
            <dd>tunai {format_money(@summary.payments_cash)}</dd>
          </div>
          <div :if={not Decimal.equal?(@summary.cash_in, Decimal.new(0))} class="flex justify-between text-primary">
            <dt>Cash in (setoran/tambah modal)</dt><dd>+{format_money(@summary.cash_in)}</dd>
          </div>
          <div :if={not Decimal.equal?(@summary.cash_out, Decimal.new(0))} class="flex justify-between text-error">
            <dt>Cash out (pengeluaran/bayar konsinyasi)</dt><dd>−{format_money(@summary.cash_out)}</dd>
          </div>
          <div class="flex justify-between border-t border-outline-variant pt-1 font-medium">
            <dt>Expected cash</dt>
            <dd>{format_money(@summary.expected_cash)}</dd>
          </div>
        </dl>
      </.md_card>

      <form phx-change="close_change" phx-submit="close_shift" class="mt-4 space-y-3">
        <.md_text_field
          type="number"
          name="counted_cash"
          value={@counted_cash}
          label="Counted cash (hitung fisik)"
          min="0"
          step="1"
          required
        />

        <div class="flex justify-between text-body-md font-medium">
          <span>Variance</span>
          <span class={variance_class(@counted_cash, @summary)}>
            {format_money(preview_variance(@counted_cash, @summary))}
          </span>
        </div>

        <.md_text_field name="note" value={@close_note} label="Note (optional)" />

        <.md_button variant="danger" class="w-full">Close shift</.md_button>
      </form>
    </.md_dialog>

    <.md_dialog :if={@movement_open and @shift} id="movement-modal" show on_cancel={JS.push("toggle_movement")}>
      <:title>Catat kas laci</:title>
      <p class="mt-1 text-body-md text-on-surface-variant">
        Uang masuk/keluar laci di tengah shift (setoran, pengeluaran, bayar konsinyasi).
      </p>

      <form phx-change="movement_change" phx-submit="save_movement" class="mt-4 space-y-3">
        <.md_text_field
          type="select"
          name="category"
          label="Tipe"
          value={@mv_category}
          options={Enum.map(movement_category_options(), fn {value, label} -> {label, value} end)}
        />

        <.md_text_field
          :if={@mv_category == "consignment_payment"}
          type="select"
          name="supplier_id"
          label="Supplier"
          value={@mv_supplier_id}
          prompt="— pilih supplier —"
          options={Enum.map(@supplier_options, fn {name, id} -> {name, to_string(id)} end)}
        />

        <.md_text_field
          id="movement-amount-input"
          name="amount"
          value={@mv_amount}
          label="Jumlah"
          phx-hook="MoneyInput"
          phx-update="ignore"
          inputmode="numeric"
          placeholder="0"
          required
        />

        <.md_text_field name="note" value={@mv_note} label="Catatan (opsional)" />

        <.md_button class="w-full">Simpan</.md_button>
      </form>
    </.md_dialog>
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
