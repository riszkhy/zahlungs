defmodule ZahlungsWeb.ServiceLive.Index do
  @moduledoc """
  The cashier's Layanan screen (PPOB, Fase 0): pick a service, enter the
  customer's number, take the money and record it (processing). After doing
  the top-up in the provider's app, the cashier marks it done (with the token
  or serial number) or failed (and hands the money back).

  Sells in the open shift's store, from that store's deposit account; both come
  from the shift (see `Zahlungs.Services.record/3`).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, Services, Shifts, Stores}
  alias Zahlungs.Services.Product

  @blank_form %{
    "customer_ref" => "",
    "bill_amount" => "",
    "payment_method" => "cash",
    "amount_paid" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    shift = Shifts.current_shift(socket.assigns.current_user)
    store = shift && Stores.get_store!(shift.store_id)

    {:ok,
     socket
     |> assign(page_title: "Layanan", shift: shift, store: store)
     |> assign(:sellable, store != nil and Deposits.active_account?(store.deposit_account_id))
     |> assign(category: "pulsa", selected: nil, form: @blank_form, preview: nil)
     |> load_products()
     |> load_transactions()}
  end

  @impl true
  def handle_event("set_category", %{"category" => category}, socket) do
    if category in Product.categories() do
      {:noreply,
       socket |> assign(category: category, selected: nil, preview: nil) |> load_products()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.products, &(to_string(&1.id) == to_string(id)))
    {:noreply, socket |> assign(:selected, selected) |> preview()}
  end

  def handle_event("change", %{"service" => params}, socket) do
    {:noreply, socket |> assign(:form, clean(params)) |> preview()}
  end

  def handle_event("record", %{"service" => params}, socket) do
    form = clean(params)

    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "Pilih produk dulu.")}

      product ->
        case Services.record(socket.assigns.current_user, product.id, form) do
          {:ok, _transaction} ->
            {:noreply,
             socket
             |> put_flash(:info, "Dicatat. Proses di aplikasi penyedia, lalu tandai hasilnya.")
             |> assign(form: @blank_form, preview: nil)
             |> load_transactions()}

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
    |> after_marking(socket, &"Kembalikan #{format_money(&1.price)} ke pelanggan.")
  end

  defp after_marking({:ok, transaction}, socket, message) do
    {:noreply, socket |> put_flash(:info, message.(transaction)) |> load_transactions()}
  end

  defp after_marking({:error, reason}, socket, _message) do
    {:noreply, socket |> put_flash(:error, error_message(reason)) |> load_transactions()}
  end

  # A transaction of the shift's store only; another store's raises (404).
  defp transaction!(socket, id) do
    scope = %{socket.assigns.current_scope | store: socket.assigns.store}
    Services.get_transaction!(scope, id)
  end

  defp load_products(%{assigns: %{sellable: false}} = socket), do: assign(socket, :products, [])

  defp load_products(socket) do
    assign(
      socket,
      :products,
      Services.list_products(category: socket.assigns.category, active: true)
    )
  end

  defp load_transactions(%{assigns: %{shift: nil}} = socket),
    do: assign(socket, processing: [], history: [])

  defp load_transactions(socket) do
    {processing, history} =
      socket.assigns.shift
      |> Services.list_shift_transactions()
      |> Enum.split_with(&(&1.status == "processing"))

    assign(socket, processing: processing, history: history)
  end

  # The price of the selected service (with the bill, for tagihan PLN) and the
  # change for the cash entered.
  defp preview(%{assigns: %{selected: nil}} = socket), do: assign(socket, :preview, nil)

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

  # Amounts arrive as typed ("245.000"): keep the digits only.
  defp clean(params) do
    Map.merge(@blank_form, Map.take(params, Map.keys(@blank_form)))
    |> Map.update!("bill_amount", &digits/1)
    |> Map.update!("amount_paid", &digits/1)
  end

  defp digits(value) when is_binary(value), do: String.replace(value, ~r/\D/, "")
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
  defp error_message(:insufficient_payment), do: "Uang diterima kurang dari harga."
  defp error_message(:not_processing), do: "Transaksi ini sudah ditandai."

  defp error_message(:forbidden),
    do: "Hanya kasir yang mencatat atau admin yang bisa menandai."

  defp error_message(%Ecto.Changeset{} = changeset) do
    cond do
      changeset.errors[:customer_ref] -> "Nomor tujuan harus 6–20 angka."
      changeset.errors[:failure_reason] -> "Isi alasan gagal."
      changeset.errors[:token_sn] -> "Token / SN paling panjang 64 karakter."
      true -> "Periksa isian."
    end
  end

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

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_), do: "Diproses"

  defp time(transaction, store) do
    transaction.inserted_at |> Zahlungs.LocalTime.to_local(store) |> Calendar.strftime("%H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Layanan
      <:subtitle>Pulsa, paket data, token dan tagihan PLN{if @store, do: " · #{@store.name}"}</:subtitle>
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

        <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
          <button
            :for={product <- @products}
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

        <form :if={@selected} phx-change="change" phx-submit="record" class="space-y-3">
          <div class="flex justify-between gap-2 font-medium">
            <span>{@selected.name}</span>
            <span :if={@preview}>{format_money(@preview.price)}</span>
          </div>

          <label :if={Product.bill?(@selected)} class="block text-sm">
            Nominal tagihan
            <input type="text" inputmode="numeric" name="service[bill_amount]" value={@form["bill_amount"]} class="form-control" autocomplete="off" />
          </label>

          <label class="block text-sm">
            Nomor tujuan
            <input type="text" inputmode="numeric" name="service[customer_ref]" value={@form["customer_ref"]} class="form-control" autocomplete="off" required />
          </label>
          <p :if={@form["customer_ref"] != ""} class="rounded bg-gray-50 py-2 text-center text-xl font-semibold tracking-wide">
            {group_digits(String.replace(@form["customer_ref"], ~r/\D/, ""))}
          </p>

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
            Catat dan terima uang
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
    </section>

    <section :if={@history != []} class="mt-6">
      <h3 class="font-semibold text-gray-700">Riwayat shift ini</h3>
      <div :for={tx <- @history} id={"history-#{tx.id}"} class="list-card mt-2">
        <span class="min-w-0 flex-1">
          <span class="block truncate font-medium">{tx.product_name} · {group_digits(tx.customer_ref)}</span>
          <span :if={tx.token_sn} class="block text-xs text-gray-500">Token / SN: {tx.token_sn}</span>
          <span :if={tx.failure_reason} class="block text-xs text-gray-500">{tx.failure_reason}</span>
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
