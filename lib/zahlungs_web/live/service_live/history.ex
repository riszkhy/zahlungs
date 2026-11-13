defmodule ZahlungsWeb.ServiceLive.History do
  @moduledoc """
  Riwayat layanan: every service of the scope's store(s), whoever recorded it,
  paged, by date, status, category, number or code. A cashier sees their
  store's, so a colleague's sale can be found when the customer comes back; an
  admin those of the store picked in the navbar. Only to look: services are
  marked and refunded on the Layanan screen. An admin may correct a final
  status here (`ZahlungsWeb.ServiceCorrection`).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{LocalTime, Scope, Services, Stores}
  alias ZahlungsWeb.ServiceCorrection
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
     |> close_correction()
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

  def handle_event("review_correction", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         transaction when not is_nil(transaction) <-
           Services.get_transaction(socket.assigns.current_scope, id),
         true <- ServiceCorrection.button?(socket.assigns.current_user, transaction) do
      {:noreply, socket |> close_correction() |> assign(:correcting, transaction)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_correction", _params, socket),
    do: {:noreply, close_correction(socket)}

  # Only while the popup is open: a second click on the way does nothing.
  def handle_event("confirm_correction", _params, %{assigns: %{correcting: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_correction", params, socket) do
    transaction = socket.assigns.correcting
    reason = params["reason"] || ""
    token_sn = params["token_sn"] || ""

    result =
      Services.correct_status(
        socket.assigns.current_user,
        transaction,
        ServiceCorrection.target(transaction),
        reason,
        token_sn: token_sn
      )

    {kind, text} = ServiceCorrection.message(result)

    case result do
      {:error, error} ->
        if ServiceCorrection.keep_open?(error) do
          {:noreply,
           assign(socket,
             correction_error: text,
             correction_reason: reason,
             correction_token_sn: token_sn
           )}
        else
          {:noreply, socket |> close_correction() |> put_flash(kind, text)}
        end

      {:ok, _transaction} ->
        {:noreply, socket |> close_correction() |> put_flash(kind, text) |> load_transactions()}
    end
  end

  @impl true
  def handle_info({:service_changed, _id}, socket), do: {:noreply, load_transactions(socket)}

  defp close_correction(socket),
    do:
      assign(socket,
        correcting: nil,
        correction_error: nil,
        correction_reason: "",
        correction_token_sn: ""
      )

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

  defp corrector(%{corrected_by: %{} = admin}), do: admin.name || admin.email
  defp corrector(_transaction), do: "admin"

  defp corrected_time(transaction) do
    transaction.corrected_at
    |> LocalTime.to_local(transaction.store)
    |> Calendar.strftime("%d %b %Y %H:%M")
  end

  attr :transaction, :map, required: true
  attr :user, :map, required: true

  defp correct_button(assigns) do
    ~H"""
    <.md_button
      :if={ServiceCorrection.button?(@user, @transaction)}
      variant="text"
      type="button"
      phx-click="review_correction"
      phx-value-id={@transaction.id}
      class="!h-8 !px-2 !text-label-md"
    >
      Koreksi status
    </.md_button>
    """
  end

  # The failure or provider's note, unless it only repeats the correction's
  # reason (a correction to failed makes its reason the failure reason).
  defp note(transaction) do
    case transaction.failure_reason || transaction.provider_message do
      note when transaction.corrected_at != nil and note == transaction.correction_reason -> nil
      note -> note
    end
  end

  attr :transaction, :map, required: true

  defp outcome(assigns) do
    ~H"""
    <span :if={@transaction.token_sn} class="block break-words text-body-sm text-on-surface-variant">
      Token / SN: {Layanan.token_text(@transaction.token_sn)}
    </span>
    <span :if={@transaction.corrected_at} class="block break-words text-body-sm text-on-surface-variant">
      Dikoreksi {corrector(@transaction)}, {corrected_time(@transaction)}: {@transaction.correction_reason}
    </span>
    <span :if={@transaction.review_reason} class="block text-body-sm font-medium text-warning">
      Perlu ditinjau — admin akan meninjau
    </span>
    <span :if={note(@transaction)} class="block text-body-sm text-on-surface-variant">
      {note(@transaction)}
    </span>
    <.link
      :if={@transaction.status == "success"}
      href={~p"/services/#{@transaction.id}/receipt"}
      target="_blank"
      class="block text-body-sm text-primary hover:underline"
    >
      Cetak struk
    </.link>
    """
  end

  @status_options [
    {"Semua status", ""},
    {"Diproses", "processing"},
    {"Berhasil", "success"},
    {"Gagal", "failed"}
  ]

  defp category_options,
    do: [{"Semua kategori", ""} | Enum.map(Services.categories(), fn {v, l} -> {l, v} end)]

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, status_options: @status_options, category_options: category_options())

    ~H"""
    <div class="md3 -m-6 rounded-xl bg-surface p-4 text-on-surface">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h1 class="text-headline-sm">Riwayat layanan</h1>
          <p class="mt-1 text-body-md text-on-surface-variant">
            Semua transaksi pulsa, paket data, token PLN dan tagihan
          </p>
        </div>
        <.md_button variant="outlined" navigate={~p"/services"}>Layanan</.md_button>
      </div>

      <form
        id="history-filter"
        phx-change="filter"
        phx-submit="filter"
        class="mt-6 grid grid-cols-2 items-end gap-3 lg:grid-cols-6"
      >
        <.md_text_field type="date" name="from" value={@from} label="Dari" />
        <.md_text_field type="date" name="to" value={@to} label="Sampai" />
        <.md_text_field
          type="select"
          name="status"
          value={@status}
          label="Status"
          options={@status_options}
        />
        <.md_text_field
          type="select"
          name="category"
          value={@category}
          label="Kategori"
          options={@category_options}
        />
        <div class="col-span-2">
          <.md_search
            id="history-search"
            name="q"
            value={@q}
            placeholder="Nomor tujuan atau kode"
            phx-debounce="300"
            autocomplete="off"
            aria-label="Cari"
          />
        </div>
      </form>

      <p :if={not @valid_dates} class="mt-6 text-body-md text-on-surface-variant">
        Pilih rentang tanggal yang valid.
      </p>
      <p :if={@valid_dates and @transactions == []} class="mt-6 text-body-md text-on-surface-variant">
        Belum ada transaksi layanan pada pilihan ini.
      </p>

      <%!-- Below landscape-tablet width a row doesn't fit: one card per service. --%>
      <div :if={@transactions != []} class="mt-4 space-y-2 lg:hidden">
        <div
          :for={tx <- @transactions}
          id={"service-card-#{tx.id}"}
          class="flex items-center gap-3 rounded-md3-md bg-surface-container-low p-3 text-body-md"
        >
          <span class="min-w-0 flex-1">
            <span class="block truncate font-medium">{tx.product_name}</span>
            <span class="block font-medium">{Layanan.group_digits(tx.customer_ref)}</span>
            <span class="block text-body-sm text-on-surface-variant">
              {time(tx)} · {tx.code} · {cashier(tx)}
              <span :if={is_nil(@current_scope.store)}>· {tx.store.name}</span>
            </span>
            <.outcome transaction={tx} />
          </span>
          <span class="flex shrink-0 flex-col items-end gap-1 text-right">
            <span class="block text-title-sm">{format_price(tx.price)}</span>
            <ServiceCorrection.status_badge status={tx.status} />
            <.correct_button transaction={tx} user={@current_user} />
          </span>
        </div>
      </div>

      <div
        :if={@transactions != []}
        id="service-history"
        class="mt-4 hidden overflow-x-auto rounded-md3-lg bg-surface-container-lowest lg:block"
      >
        <table class="w-full">
          <thead>
            <tr class="text-left text-label-md text-on-surface-variant">
              <th class="px-3 py-2">Waktu</th>
              <th class="px-3 py-2">Kode</th>
              <th class="px-3 py-2">Produk</th>
              <th class="px-3 py-2">Nomor tujuan</th>
              <th :if={is_nil(@current_scope.store)} class="px-3 py-2">Cabang</th>
              <th class="px-3 py-2">Kasir</th>
              <th class="px-3 py-2">Harga</th>
              <th class="px-3 py-2">Status</th>
            </tr>
          </thead>
          <tbody class="text-body-md">
            <tr
              :for={tx <- @transactions}
              id={"service-history-#{tx.id}"}
              class="border-t border-outline-variant"
            >
              <td class="px-3 py-2 align-top">{time(tx)}</td>
              <td class="px-3 py-2 align-top">{tx.code}</td>
              <td class="px-3 py-2 align-top">{tx.product_name}</td>
              <td class="px-3 py-2 align-top">{Layanan.group_digits(tx.customer_ref)}</td>
              <td :if={is_nil(@current_scope.store)} class="px-3 py-2 align-top">{tx.store.name}</td>
              <td class="px-3 py-2 align-top">{cashier(tx)}</td>
              <td class="px-3 py-2 align-top">{format_price(tx.price)}</td>
              <td class="px-3 py-2 align-top">
                <ServiceCorrection.status_badge status={tx.status} />
                <.outcome transaction={tx} />
                <.correct_button transaction={tx} user={@current_user} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} per_page={@per_page} total={@total} noun="transaksi" />

      <ServiceCorrection.popup
        :if={@correcting}
        transaction={@correcting}
        error={@correction_error}
        reason={@correction_reason}
        token_sn={@correction_token_sn}
      />
    </div>
    """
  end
end
