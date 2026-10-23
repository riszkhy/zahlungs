defmodule ZahlungsWeb.ServiceLive.Index do
  @moduledoc """
  The cashier's Layanan screen (PPOB). Sells in the open shift's store, from
  that store's deposit account; both come from the shift (see
  `Zahlungs.Services.record/3`).

  - **Manual account (Fase 0):** pick a service, enter the number, take the
    money and record it; after the top-up in the provider's own app, mark it
    done (with the token or serial number) or failed.
  - **Api account (Fase 1):** a PLN bill is checked with the provider first
    (Cek tagihan) and paid from that answer; every service is sent to the
    provider, whose answer arrives by itself (`Zahlungs.Services.subscribe/1`).
    Pending ones can be checked now; failed ones wait under "Perlu
    dikembalikan" until the cashier confirms the money went back.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, Services, Shifts, Stores}
  alias Zahlungs.Services.{Brand, Product}
  alias ZahlungsWeb.AmountInput

  @blank_form %{
    "customer_ref" => "",
    "months" => "1",
    "bill_amount" => "",
    "payment_method" => "cash",
    "amount_paid" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    shift = Shifts.current_shift(socket.assigns.current_user)
    store = shift && Stores.get_store!(shift.store_id)
    account = store && Deposits.get_active_account(store.deposit_account_id)

    if connected?(socket) && store, do: Services.subscribe(store.id)

    {:ok,
     socket
     |> assign(page_title: "Layanan", shift: shift, store: store)
     |> assign(sellable: account != nil, api: account != nil and Deposits.api?(account))
     |> assign(category: "pulsa", brand: nil, selected: nil, form: @blank_form)
     |> assign(preview: nil, inquiry: nil)
     |> load_products()
     |> load_transactions()}
  end

  @impl true
  def handle_event("set_category", %{"category" => category}, socket) do
    if category in Product.categories() do
      {:noreply,
       socket
       |> assign(category: category, brand: nil, selected: nil, preview: nil, inquiry: nil)
       |> load_products()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.products, &(to_string(&1.id) == to_string(id)))
    {:noreply, socket |> assign(selected: selected, inquiry: nil) |> preview()}
  end

  def handle_event("change", %{"service" => params}, socket) do
    form = clean(params, socket.assigns.form)

    {:noreply,
     socket |> assign(:form, form) |> detect_brand() |> drop_stale_inquiry() |> preview()}
  end

  # "" shows every product, "other" the ones without a brand.
  def handle_event("set_brand", %{"brand" => brand}, socket) do
    if brand in ["", "other" | Brand.keys()] do
      {:noreply, socket |> assign(:brand, if(brand != "", do: brand)) |> keep_selected()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("inquire", %{"service" => params}, socket) do
    form = clean(params, socket.assigns.form)
    socket = assign(socket, :form, form)

    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "Pilih produk dulu.")}

      product ->
        case Services.inquire(socket.assigns.current_user, product.id, form["customer_ref"],
               months: form["months"]
             ) do
          {:ok, inquiry} ->
            {:noreply,
             socket
             |> assign(inquiry: inquiry, form: %{form | "customer_ref" => inquiry.customer_ref})
             |> preview()}

          {:error, reason} ->
            {:noreply,
             socket |> assign(:inquiry, nil) |> put_flash(:error, error_message(reason))}
        end
    end
  end

  def handle_event("record", %{"service" => params}, socket) do
    form = clean(params, socket.assigns.form)

    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "Pilih produk dulu.")}

      product ->
        case Services.record(socket.assigns.current_user, product.id, record_attrs(form, socket)) do
          {:ok, transaction} ->
            {:noreply,
             socket
             |> put_flash(:info, recorded_message(transaction))
             |> assign(form: @blank_form, preview: nil, inquiry: nil)
             |> load_transactions()}

          {:error, :price_changed} ->
            {:noreply, socket |> assign(:form, form) |> price_changed(product)}

          {:error, :inquiry_expired} ->
            {:noreply,
             socket
             |> assign(form: form, inquiry: nil, preview: nil)
             |> put_flash(:error, error_message(:inquiry_expired))}

          {:error, reason} ->
            {:noreply, socket |> assign(:form, form) |> put_flash(:error, error_message(reason))}
        end
    end
  end

  def handle_event("mark_success", %{"transaction_id" => id} = params, socket) do
    socket
    |> transaction!(id)
    |> Services.mark_success(socket.assigns.current_user, params["token_sn"])
    |> after_marking(socket, fn _ -> "Berhasil dicatat." end)
  end

  def handle_event("mark_failed", %{"transaction_id" => id} = params, socket) do
    socket
    |> transaction!(id)
    |> Services.mark_failed(socket.assigns.current_user, params["reason"])
    |> after_marking(socket, &refund_message/1)
  end

  def handle_event("check_status", %{"transaction_id" => id}, socket) do
    transaction = transaction!(socket, id)

    message =
      case Services.check_status(transaction.id) do
        {:ok, %{status: "success"}} ->
          {:info, "Berhasil."}

        {:ok, %{status: "failed"} = failed} ->
          {:info, "Gagal di penyedia. " <> refund_message(failed)}

        {:ok, %{status: "processing"}} ->
          {:info, "Masih menunggu penyedia."}

        {:ok, :already_final} ->
          {:info, "Transaksi ini sudah selesai."}
      end

    {:noreply, socket |> put_flash(elem(message, 0), elem(message, 1)) |> load_transactions()}
  end

  def handle_event("confirm_refund", %{"transaction_id" => id}, socket) do
    transaction = transaction!(socket, id)

    case Services.confirm_refund(transaction, socket.assigns.current_user) do
      {:ok, _refunded} ->
        {:noreply, socket |> put_flash(:info, "Pengembalian dicatat.") |> load_transactions()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> load_transactions()}
    end
  end

  # A service of this store changed (the provider answered, or another tab).
  @impl true
  def handle_info({:service_changed, _id}, socket), do: {:noreply, load_transactions(socket)}

  # An api bill is paid from its inquiry, kept on the server; the screen only
  # says which one.
  defp record_attrs(form, socket) do
    form = quoted(form, socket)

    case socket.assigns.inquiry do
      nil -> form
      inquiry -> Map.put(form, "inquiry_id", inquiry.id)
    end
  end

  defp recorded_message(%{channel: "api"}), do: "Dikirim ke penyedia."

  defp recorded_message(_manual),
    do: "Dicatat. Proses di aplikasi penyedia, lalu tandai hasilnya."

  defp brand_category?(category), do: category in ~w(pulsa paket_data)

  # Pulsa and paket data: the number's prefix picks the brand. A number too
  # short to tell, or one of no known brand, leaves the choice as it was.
  defp detect_brand(%{assigns: %{category: category, form: form}} = socket) do
    with true <- brand_category?(category),
         brand when is_binary(brand) <- Brand.detect(form["customer_ref"]) do
      socket |> assign(:brand, brand) |> keep_selected()
    else
      _ -> socket
    end
  end

  # A selected product of another brand is let go, so it isn't sold to this
  # number; one without a brand stays selected.
  defp keep_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp keep_selected(%{assigns: %{selected: selected, brand: brand}} = socket) do
    if selected.operator in [nil, brand] or brand in [nil, "other"],
      do: socket,
      else: assign(socket, selected: nil, preview: nil, inquiry: nil)
  end

  defp shown?(_product, nil), do: true
  defp shown?(product, "other"), do: is_nil(product.operator)
  defp shown?(product, brand), do: product.operator == brand

  defp shown_products(products, brand), do: Enum.filter(products, &shown?(&1, brand))

  # The brands that have products, in the usual order, and "Lainnya" when
  # some product has none.
  defp brand_chips(products) do
    operators = MapSet.new(products, & &1.operator)
    chips = for {label, key} <- Brand.options(), key in operators, do: {label, key}
    if nil in operators, do: chips ++ [{"Lainnya", "other"}], else: chips
  end

  # A number changed after Cek tagihan no longer matches what was checked.
  defp drop_stale_inquiry(%{assigns: %{inquiry: nil}} = socket), do: socket

  defp drop_stale_inquiry(%{assigns: %{inquiry: inquiry, form: form}} = socket) do
    if digits(form["customer_ref"]) == inquiry.customer_ref and months_kept?(inquiry, form),
      do: socket,
      else: assign(socket, inquiry: nil, preview: nil)
  end

  # Other months than the ones checked need a new check; an inquiry without
  # months (a bill that doesn't ask) doesn't care about the field.
  defp months_kept?(%{months: nil}, _form), do: true

  defp months_kept?(%{months: months}, form) do
    case Integer.parse(form["months"] || "") do
      {^months, ""} -> true
      _ -> false
    end
  end

  # Cash comes back out of the drawer; other payments are refunded the way
  # they were paid, and never from the drawer (they never went into it).
  defp refund_message(%{payment_method: "cash", price: price}),
    do: "Kembalikan #{format_money(price)} ke pelanggan."

  defp refund_message(%{payment_method: method, price: price}),
    do:
      "Kembalikan #{format_money(price)} ke pelanggan lewat #{payment_label(method)}, bukan dari laci."

  defp payment_label("qris"), do: "QRIS"
  defp payment_label("card"), do: "kartu"
  defp payment_label("transfer"), do: "transfer"
  defp payment_label(other), do: other

  # The price on screen goes along, so a price changed meanwhile is refused.
  defp quoted(form, %{assigns: %{preview: %{price: price}}}),
    do: Map.put(form, "expected_price", Decimal.to_string(price))

  defp quoted(form, _socket), do: form

  # Reloads the product so the screen shows what it costs now.
  defp price_changed(socket, product) do
    socket = load_products(socket)
    fresh = Enum.find(socket.assigns.products, &(&1.id == product.id))
    socket = socket |> assign(:selected, fresh) |> preview()

    message =
      case socket.assigns.preview do
        %{price: price} ->
          "Harga #{product.name} berubah menjadi #{format_money(price)}. Sampaikan ke pelanggan, lalu catat lagi."

        nil ->
          "Harga #{product.name} berubah. Pilih produknya lagi."
      end

    put_flash(socket, :error, message)
  end

  defp after_marking({:ok, transaction}, socket, message) do
    {:noreply, socket |> put_flash(:info, message.(transaction)) |> load_transactions()}
  end

  defp after_marking({:error, reason}, socket, _message) do
    {:noreply, socket |> put_flash(:error, error_message(reason)) |> load_transactions()}
  end

  defp shift_scope(socket), do: %{socket.assigns.current_scope | store: socket.assigns.store}

  # A transaction of the shift's store only; another store's raises (404).
  defp transaction!(socket, id), do: Services.get_transaction!(shift_scope(socket), id)

  defp load_products(%{assigns: %{sellable: false}} = socket), do: assign(socket, :products, [])

  defp load_products(socket) do
    assign(
      socket,
      :products,
      Services.list_products(category: socket.assigns.category, active: true)
    )
  end

  defp load_transactions(%{assigns: %{shift: nil}} = socket),
    do: assign(socket, processing: [], history: [], refunds: [])

  defp load_transactions(socket) do
    {processing, history} =
      socket.assigns.shift
      |> Services.list_shift_transactions()
      |> Enum.split_with(&(&1.status == "processing"))

    assign(socket,
      processing: processing,
      history: history,
      refunds: Services.list_refunds_due(shift_scope(socket))
    )
  end

  # The price of the selected service — from the inquiry for an api bill, with
  # the bill typed in for a manual one — and the change for the cash entered.
  defp preview(%{assigns: %{selected: nil}} = socket), do: assign(socket, :preview, nil)

  defp preview(%{assigns: %{inquiry: %Services.Inquiry{} = inquiry, form: form}} = socket) do
    %{price: price} = Services.inquiry_price(inquiry)
    assign(socket, :preview, %{price: price, change: change(form, price)})
  end

  defp preview(%{assigns: %{selected: product, form: form}} = socket) do
    case Services.price_for(product, form["bill_amount"]) do
      {:ok, %{price: price}} ->
        assign(socket, :preview, %{price: price, change: change(form, price)})

      {:error, _} ->
        assign(socket, :preview, nil)
    end
  end

  defp change(%{"payment_method" => "cash", "amount_paid" => paid}, price) when paid != "" do
    difference = Decimal.sub(Decimal.new(paid), price)
    if Decimal.negative?(difference), do: nil, else: difference
  end

  defp change(_form, _price), do: nil

  # Amounts arrive as typed ("245.000", "245.000,00"); fields not in this
  # submit keep what the form had.
  defp clean(params, form) do
    Map.merge(form, Map.take(params, Map.keys(@blank_form)))
    |> Map.update!("bill_amount", &AmountInput.parse/1)
    |> Map.update!("amount_paid", &AmountInput.parse/1)
  end

  defp digits(value) when is_binary(value), do: String.replace(value, ~r/[\s\-\.\+]/, "")
  defp digits(_value), do: ""

  @doc "A number in groups of four from the left, to read out: `0812 3456 7890`."
  def group_digits(number) when is_binary(number) do
    number
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  defp error_message(:no_open_shift), do: "Buka shift dulu di Cashier."

  defp error_message(:no_deposit_account),
    do: "Toko ini belum punya akun deposit aktif. Minta admin mengaturnya."

  defp error_message(:product_unavailable), do: "Produk ini sudah tidak tersedia."
  defp error_message(:bill_required), do: "Isi nominal tagihan."
  defp error_message(:invalid_months), do: "Jumlah bulan harus 1–12."
  defp error_message(:insufficient_payment), do: "Uang diterima kurang dari harga."
  defp error_message(:not_processing), do: "Transaksi ini sudah ditandai."

  defp error_message(:forbidden),
    do: "Hanya kasir yang mencatat atau admin yang bisa menandai."

  defp error_message(:not_found), do: "ID pelanggan tidak ditemukan."
  defp error_message(:already_paid), do: "Tagihan ini sudah lunas."
  defp error_message(:unavailable), do: "Penyedia tidak tersedia, coba lagi."
  defp error_message({:rejected, message}), do: message

  defp error_message(:inquiry_expired),
    do: "Hasil cek tagihan sudah tidak berlaku. Cek tagihan lagi."

  defp error_message(:no_provider_code),
    do: "Produk ini belum punya kode vendor. Minta admin melengkapinya."

  defp error_message(:not_api), do: "Akun deposit toko ini mode manual."
  defp error_message(:not_manual), do: "Transaksi ini diselesaikan oleh penyedia."
  defp error_message(:not_refundable), do: "Pengembalian ini sudah dicatat."

  defp error_message(:in_review),
    do: "Transaksi ini sedang ditinjau admin. Jangan kembalikan uang dulu."

  defp error_message(:other_store), do: "Transaksi ini milik toko lain."

  defp error_message(%Ecto.Changeset{} = changeset) do
    cond do
      changeset.errors[:customer_ref] -> "Nomor tujuan harus 6–20 angka."
      changeset.errors[:failure_reason] -> "Isi alasan gagal."
      changeset.errors[:token_sn] -> "Token / SN paling panjang 64 karakter."
      true -> "Periksa isian."
    end
  end

  defp error_message(_other), do: "Gagal. Coba lagi."

  defp category_label(category) do
    Enum.find_value(Services.categories(), category, fn {value, label} ->
      if value == category, do: label
    end)
  end

  defp tile_price(product) do
    case Services.price_for(product, nil) do
      {:ok, %{price: price}} -> format_money(price)
      {:error, :bill_required} -> "Tagihan + admin"
    end
  end

  # An api bill that asks has the cashier choose the months before the check.
  defp ask_months?(%{api: true, selected: %Product{category: "tagihan", ask_months: true}}),
    do: true

  defp ask_months?(_assigns), do: false

  # An api service the provider has left waiting may be marked by an admin.
  defp by_hand?(transaction, user),
    do: user.role == "admin" and Services.awaiting_too_long?(transaction)

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_), do: "Diproses"

  defp time(transaction, store) do
    transaction.inserted_at |> Zahlungs.LocalTime.to_local(store) |> Calendar.strftime("%H:%M")
  end

  # On an api account, a bill and a token PLN are checked with the provider
  # before the money is taken.
  defp checked?(%{api: true, selected: %Product{category: "tagihan"}}), do: true

  defp checked?(%{api: true, selected: %Product{category: "token_pln", owner_check: check}}),
    do: check

  defp checked?(_assigns), do: false

  # The shop's extra fee on an inquired bill: the price above the provider's total.
  defp extra_fee(%{price: price}, inquiry),
    do: Decimal.sub(price, inquiry.provider_total || inquiry.bill_amount)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, api_bill: checked?(assigns), ask_months: ask_months?(assigns))

    ~H"""
    <.header>
      Layanan
      <:subtitle>Pulsa, paket data, token PLN dan tagihan{if @store, do: " · #{@store.name}"}</:subtitle>
    </.header>

    <div :if={is_nil(@shift)} class="mt-6 rounded-lg border border-gray-200 bg-gray-50 p-5">
      <p class="font-medium text-gray-800">Belum ada shift</p>
      <p class="mt-1 text-sm text-gray-600">Buka shift dulu untuk mencatat layanan.</p>
      <.link navigate={~p"/cashier"} class="btn btn-primary mt-4 inline-flex items-center">
        Buka shift di Cashier
      </.link>
    </div>

    <div :if={@shift && not @sellable} class="mt-6 rounded-lg border border-amber-200 bg-amber-50 p-5 text-sm text-amber-800">
      Toko ini belum punya akun deposit aktif. Minta admin mengaturnya di menu Deposit.
    </div>

    <section :if={@refunds != []} id="refunds-due" class="mt-6 rounded-lg border border-red-200 bg-red-50 p-4">
      <h3 class="font-semibold text-red-800">Perlu dikembalikan ({length(@refunds)})</h3>
      <div :for={tx <- @refunds} id={"refund-#{tx.id}"} class="mt-2 flex flex-wrap items-center justify-between gap-2 text-sm">
        <span>
          <span class="font-medium">{tx.product_name}</span>
          · {group_digits(tx.customer_ref)} · {refund_message(tx)}
          <span :if={tx.failure_reason || tx.provider_message} class="block text-xs text-red-700">
            {tx.failure_reason || tx.provider_message}
          </span>
        </span>
        <button
          type="button"
          phx-click={JS.push("confirm_refund", value: %{transaction_id: tx.id})}
          phx-disable-with="Mencatat..."
          class="chip"
        >
          Uang sudah dikembalikan
        </button>
      </div>
    </section>

    <div :if={@sellable} class="mt-6 grid gap-4 lg:grid-cols-5">
      <section class="lg:col-span-3">
        <div class="flex flex-wrap gap-2">
          <button
            :for={{value, label} <- Services.categories()}
            type="button"
            phx-click="set_category"
            phx-value-category={value}
            class={["chip", @category == value && "chip-active"]}
          >
            {label}
          </button>
        </div>

        <div :if={brand_category?(@category)} class="mt-3">
          <form id="brand-number" phx-change="change" phx-submit="change">
            <label class="block text-sm">
              Nomor tujuan
              <input type="text" inputmode="numeric" name="service[customer_ref]" value={@form["customer_ref"]} class="form-control" autocomplete="off" />
            </label>
          </form>
          <div class="mt-2 flex flex-wrap gap-2">
            <button type="button" phx-click="set_brand" phx-value-brand="" class={["chip", is_nil(@brand) && "chip-active"]}>
              Semua
            </button>
            <button
              :for={{label, key} <- brand_chips(@products)}
              type="button"
              phx-click="set_brand"
              phx-value-brand={key}
              class={["chip", @brand == key && "chip-active"]}
            >
              {label}
            </button>
          </div>
        </div>

        <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
          <button
            :for={product <- shown_products(@products, @brand)}
            type="button"
            phx-click={JS.push("select", value: %{id: product.id})}
            class={["product-tile", @selected && @selected.id == product.id && "!border-green-700 ring-2 ring-green-200"]}
          >
            <span class="block font-medium text-gray-800">{product.name}</span>
            <span class="mt-1 block text-gray-500">{tile_price(product)}</span>
          </button>
        </div>
        <p :if={@products == []} class="mt-3 text-sm text-gray-500">
          Belum ada produk {category_label(@category)}. Admin menambahkannya di menu Produk layanan.
        </p>
      </section>

      <section class="cart-panel lg:col-span-2">
        <p :if={is_nil(@selected)} class="text-sm text-gray-500">Pilih produk di kiri.</p>

        <%!-- An api bill or token: check it with the provider first. --%>
        <form :if={@api_bill} phx-change="change" phx-submit="inquire" class="space-y-3">
          <p class="font-medium">{@selected.name}</p>
          <label class="block text-sm">
            {if Product.bill?(@selected), do: "ID pelanggan", else: "Nomor meter / ID pelanggan"}
            <input type="text" inputmode="numeric" name="service[customer_ref]" value={@form["customer_ref"]} class="form-control" autocomplete="off" required />
          </label>
          <label :if={@ask_months} class="block text-sm">
            Jumlah bulan
            <select name="service[months]" class="form-control">
              <option :for={month <- 1..12} value={month} selected={@form["months"] == to_string(month)}>
                {month}
              </option>
            </select>
          </label>
          <button type="submit" phx-disable-with="Mengecek..." class="btn btn-primary w-full">
            {if Product.bill?(@selected), do: "Cek tagihan", else: "Cek pelanggan"}
          </button>
        </form>

        <div :if={@api_bill && @inquiry} id="inquiry" class="mt-4 rounded-lg border border-green-200 bg-green-50 p-3 text-sm">
          <p class="font-semibold text-gray-800">{@inquiry.customer_name}</p>
          <p class="text-gray-600">
            {group_digits(@inquiry.customer_ref)}<span :if={@inquiry.period}> · {@inquiry.period}</span><span :if={@inquiry.kind == "bill"}> · {@inquiry.sheets} bulan</span><span :if={@inquiry.details}> · {@inquiry.details}</span>
          </p>
          <div :if={@inquiry.kind == "bill"}>
            <div class="mt-2 flex justify-between"><span>Tagihan</span><span>{format_money(@inquiry.bill_amount)}</span></div>
            <div class="flex justify-between">
              <span>Admin penyedia</span>
              <span>{format_money(@inquiry.provider_admin || Decimal.new(0))}</span>
            </div>
            <div class="flex justify-between">
              <span>Tambahan toko</span>
              <span>{format_money(extra_fee(@preview, @inquiry))}</span>
            </div>
          </div>
          <div class="mt-1 flex justify-between font-semibold">
            <span>{if @inquiry.kind == "bill", do: "Total", else: "Harga"}</span>
            <span>{format_money(@preview.price)}</span>
          </div>
        </div>

        <form :if={@selected && (not @api_bill or @inquiry)} phx-change="change" phx-submit="record" class={["space-y-3", @api_bill && "mt-4"]}>
          <div :if={not @api_bill} class="flex justify-between gap-2 font-medium">
            <span>{@selected.name}</span>
            <span :if={@preview}>{format_money(@preview.price)}</span>
          </div>

          <label :if={not @api && Product.bill?(@selected)} class="block text-sm">
            Nominal tagihan
            <input type="text" inputmode="numeric" name="service[bill_amount]" value={@form["bill_amount"]} class="form-control" autocomplete="off" />
          </label>

          <div :if={not @api_bill}>
            <label :if={not brand_category?(@category)} class="block text-sm">
              Nomor tujuan
              <input type="text" inputmode="numeric" name="service[customer_ref]" value={@form["customer_ref"]} class="form-control" autocomplete="off" required />
            </label>
            <p :if={@form["customer_ref"] != ""} class="mt-3 rounded bg-gray-50 py-2 text-center text-xl font-semibold tracking-wide">
              {group_digits(digits(@form["customer_ref"]))}
            </p>
          </div>

          <label class="block text-sm">
            Cara bayar
            <select name="service[payment_method]" class="form-control">
              <option :for={{value, label} <- [{"cash", "Tunai"}, {"qris", "QRIS"}, {"card", "Kartu"}, {"transfer", "Transfer"}]} value={value} selected={@form["payment_method"] == value}>
                {label}
              </option>
            </select>
          </label>

          <label :if={@form["payment_method"] == "cash"} class="block text-sm">
            Uang diterima
            <input type="text" inputmode="numeric" name="service[amount_paid]" value={@form["amount_paid"]} class="form-control" autocomplete="off" />
          </label>
          <div :if={@preview && @preview.change} class="flex justify-between font-medium">
            <span>Kembalian</span>
            <span>{format_money(@preview.change)}</span>
          </div>

          <button type="submit" phx-disable-with="Mencatat..." class="btn btn-primary w-full">
            {if @api, do: "Bayar", else: "Catat dan terima uang"}
          </button>
        </form>
      </section>
    </div>

    <section :if={@shift} class="mt-6">
      <h3 class="font-semibold text-gray-700">Sedang diproses ({length(@processing)})</h3>
      <p :if={@processing == []} class="mt-2 text-sm text-gray-500">Tidak ada.</p>
      <div :for={tx <- @processing} id={"processing-#{tx.id}"} class="mt-2 rounded-lg border border-gray-200 p-3">
        <p class="text-sm">
          <span class="font-medium">{tx.product_name}</span>
          · {group_digits(tx.customer_ref)} · {format_money(tx.price)} · {time(tx, @store)}
        </p>

        <div :if={tx.channel == "api"} class="mt-2 flex flex-wrap items-center justify-between gap-2 text-sm">
          <span class="text-amber-700">
            Menunggu penyedia
            <span :if={tx.provider_message} class="block text-xs text-gray-500">{tx.provider_message}</span>
          </span>
          <button
            type="button"
            phx-click={JS.push("check_status", value: %{transaction_id: tx.id})}
            phx-disable-with="Mengecek..."
            class="chip"
          >
            Cek status
          </button>
        </div>

        <p :if={by_hand?(tx, @current_user)} class="mt-2 text-xs text-amber-800">
          Belum ada jawaban penyedia lebih dari 10 menit. Periksa di aplikasi penyedia, lalu tandai.
        </p>

        <div :if={tx.channel != "api" or by_hand?(tx, @current_user)}>
          <form phx-submit="mark_success" class="mt-2 flex flex-wrap items-center gap-2">
            <input type="hidden" name="transaction_id" value={tx.id} />
            <input type="text" name="token_sn" placeholder="Token / SN (opsional)" maxlength="64" class="form-control min-w-0 flex-1" />
            <button type="submit" class="chip">Berhasil</button>
          </form>
          <form phx-submit="mark_failed" class="mt-2 flex flex-wrap items-center gap-2">
            <input type="hidden" name="transaction_id" value={tx.id} />
            <input type="text" name="reason" placeholder="Alasan gagal" maxlength="255" required class="form-control min-w-0 flex-1" />
            <button type="submit" class="chip !border-red-300 !text-red-700">Gagal</button>
          </form>
        </div>
      </div>
    </section>

    <section :if={@history != []} class="mt-6">
      <h3 class="font-semibold text-gray-700">Riwayat shift ini</h3>
      <div :for={tx <- @history} id={"history-#{tx.id}"} class="list-card mt-2">
        <span class="min-w-0 flex-1">
          <span class="block truncate font-medium">{tx.product_name} · {group_digits(tx.customer_ref)}</span>
          <span :if={tx.token_sn} class="block text-xs text-gray-500">Token / SN: {tx.token_sn}</span>
          <span :if={tx.review_reason} class="block text-xs font-medium text-amber-700">
            Perlu ditinjau — admin akan meninjau
          </span>
          <span :if={tx.failure_reason || tx.provider_message} class="block text-xs text-gray-500">
            {tx.failure_reason || tx.provider_message}
          </span>
          <.link :if={tx.status == "success"} href={~p"/services/#{tx.id}/receipt"} target="_blank" class="text-xs text-blue-600 hover:underline">
            Cetak struk
          </.link>
        </span>
        <span class="text-right">
          <span class="block font-semibold">{format_money(tx.price)}</span>
          <span class={["inline-block rounded-full px-2 py-0.5 text-xs", tx.status == "success" && "bg-green-100 text-green-700", tx.status == "failed" && "bg-gray-200 text-gray-700"]}>
            {status_label(tx.status)}
          </span>
        </span>
      </div>
    </section>
    """
  end
end
