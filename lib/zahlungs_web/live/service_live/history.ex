defmodule ZahlungsWeb.ServiceLive.History do
  @moduledoc """
  Riwayat layanan: every service of the scope's store(s), whoever recorded it,
  paged, by date, status, category, number or code. A cashier sees their
  store's, so a colleague's sale can be found when the customer comes back; an
  admin those of the store picked in the navbar. Only to look: services are
  marked and refunded on the Layanan screen.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{LocalTime, Scope, Services, Stores}
  alias ZahlungsWeb.ServiceLive.Index, as: Layanan

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    today = LocalTime.today(scope.store)

    if connected?(socket), do: Enum.each(store_ids(scope), &Services.subscribe/1)

    {:ok,
     socket
     |> assign(page_title: "Riwayat layanan", page: 1, per_page: @per_page)
     |> assign(from: Date.to_iso8601(Date.beginning_of_month(today)), to: Date.to_iso8601(today))
     |> assign(status: "", category: "", q: "")
     |> load_transactions()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(
       from: params["from"] || "",
       to: params["to"] || "",
       status: params["status"] || "",
       category: params["category"] || "",
       q: params["q"] || "",
       page: 1
     )
     |> load_transactions()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    {:noreply, socket |> assign(:page, max(1, to_int(to))) |> load_transactions()}
  end

  @impl true
  def handle_info({:service_changed, _id}, socket), do: {:noreply, load_transactions(socket)}

  defp store_ids(scope) do
    case Scope.store_id(scope) do
      nil -> Stores.store_ids()
      store_id -> [store_id]
    end
  end

  # A page past the end (the filters or the rows changed) falls back to the
  # last one that exists.
  defp load_transactions(socket) do
    case dates(socket.assigns.from, socket.assigns.to) do
      {:ok, date_from, date_to} ->
        scope = socket.assigns.current_scope

        filters = [
          date_from: date_from,
          date_to: date_to,
          status: socket.assigns.status,
          category: socket.assigns.category,
          search: socket.assigns.q
        ]

        total = Services.count_transactions(scope, filters)
        page = min(socket.assigns.page, max(1, ceil(total / @per_page)))

        transactions =
          Services.list_transactions(
            scope,
            filters ++ [limit: @per_page, offset: (page - 1) * @per_page]
          )

        assign(socket, transactions: transactions, total: total, page: page, valid_dates: true)

      :error ->
        assign(socket, transactions: [], total: 0, page: 1, valid_dates: false)
    end
  end

  defp dates(from, to) do
    with {:ok, date_from} <- Date.from_iso8601(from),
         {:ok, date_to} <- Date.from_iso8601(to) do
      {:ok, date_from, date_to}
    else
      _ -> :error
    end
  end

  # The page buttons use JS.push, which sends the page as a JSON number.
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)

  defp time(transaction) do
    transaction.inserted_at
    |> LocalTime.to_local(transaction.store)
    |> Calendar.strftime("%d %b %Y %H:%M")
  end

  defp cashier(%{user: user}), do: user.name || user.email

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_), do: "Diproses"

  attr :transaction, :map, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-block rounded-full px-2 py-0.5 text-xs",
      @transaction.status == "success" && "bg-green-100 text-green-700",
      @transaction.status == "failed" && "bg-gray-200 text-gray-700",
      @transaction.status == "processing" && "bg-amber-100 text-amber-800"
    ]}>
      {status_label(@transaction.status)}
    </span>
    """
  end

  attr :transaction, :map, required: true

  defp outcome(assigns) do
    ~H"""
    <span :if={@transaction.token_sn} class="block break-all text-xs text-gray-500">
      Token / SN: {@transaction.token_sn}
    </span>
    <span :if={@transaction.review_reason} class="block text-xs font-medium text-amber-700">
      Perlu ditinjau — admin akan meninjau
    </span>
    <span :if={@transaction.failure_reason || @transaction.provider_message} class="block text-xs text-gray-500">
      {@transaction.failure_reason || @transaction.provider_message}
    </span>
    <.link
      :if={@transaction.status == "success"}
      href={~p"/services/#{@transaction.id}/receipt"}
      target="_blank"
      class="text-xs text-blue-600 hover:underline"
    >
      Cetak struk
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Riwayat layanan
      <:subtitle>Semua transaksi pulsa, paket data, token PLN dan tagihan</:subtitle>
      <:actions>
        <.link navigate={~p"/services"} class="chip">Layanan</.link>
      </:actions>
    </.header>

    <form id="history-filter" phx-change="filter" phx-submit="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm">Dari <input type="date" name="from" value={@from} class="form-control" /></label>
      <label class="text-sm">Sampai <input type="date" name="to" value={@to} class="form-control" /></label>
      <label class="text-sm">
        Status
        <select name="status" class="form-control">
          <option value="" selected={@status == ""}>Semua status</option>
          <option value="processing" selected={@status == "processing"}>Diproses</option>
          <option value="success" selected={@status == "success"}>Berhasil</option>
          <option value="failed" selected={@status == "failed"}>Gagal</option>
        </select>
      </label>
      <label class="text-sm">
        Kategori
        <select name="category" class="form-control">
          <option value="" selected={@category == ""}>Semua kategori</option>
          <option :for={{value, label} <- Services.categories()} value={value} selected={@category == value}>
            {label}
          </option>
        </select>
      </label>
      <label class="text-sm">
        Cari
        <input
          type="search"
          name="q"
          value={@q}
          phx-debounce="300"
          placeholder="Nomor tujuan atau kode"
          class="form-control"
          autocomplete="off"
        />
      </label>
    </form>

    <p :if={not @valid_dates} class="mt-6 text-sm text-gray-500">Pilih rentang tanggal yang valid.</p>
    <p :if={@valid_dates and @transactions == []} class="mt-6 text-sm text-gray-500">
      Belum ada transaksi layanan pada pilihan ini.
    </p>

    <%!-- Below landscape-tablet width a row doesn't fit: one card per service. --%>
    <div :if={@transactions != []} class="mt-4 space-y-2 lg:hidden">
      <div :for={tx <- @transactions} id={"service-card-#{tx.id}"} class="list-card">
        <span class="min-w-0 flex-1">
          <span class="block truncate font-medium">{tx.product_name} · {Layanan.group_digits(tx.customer_ref)}</span>
          <span class="block text-xs text-gray-500">
            {time(tx)} · {tx.code} · {cashier(tx)}
            <span :if={is_nil(@current_scope.store)}>· {tx.store.name}</span>
          </span>
          <.outcome transaction={tx} />
        </span>
        <span class="text-right">
          <span class="block font-semibold">{format_price(tx.price)}</span>
          <.status_badge transaction={tx} />
        </span>
      </div>
    </div>

    <div :if={@transactions != []} class="hidden lg:block">
      <.table id="service-history" rows={@transactions}>
        <:col :let={tx} label="Waktu">{time(tx)}</:col>
        <:col :let={tx} label="Kode">{tx.code}</:col>
        <:col :let={tx} label="Produk">{tx.product_name}</:col>
        <:col :let={tx} label="Nomor tujuan">{Layanan.group_digits(tx.customer_ref)}</:col>
        <:col :let={tx} :if={is_nil(@current_scope.store)} label="Cabang">{tx.store.name}</:col>
        <:col :let={tx} label="Kasir">{cashier(tx)}</:col>
        <:col :let={tx} label="Harga">{format_price(tx.price)}</:col>
        <:col :let={tx} label="Status">
          <.status_badge transaction={tx} />
          <.outcome transaction={tx} />
        </:col>
      </.table>
    </div>

    <.pagination page={@page} per_page={@per_page} total={@total} noun="transaksi" />
    """
  end
end
