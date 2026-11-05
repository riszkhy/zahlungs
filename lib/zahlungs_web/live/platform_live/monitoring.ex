defmodule ZahlungsWeb.PlatformLive.Monitoring do
  @moduledoc """
  The platform operator's overview of every organization: still in use, how big,
  to be billed, services in trouble. Read only; approvals and billing stay on
  `PlatformLive.Organizations`.

  The figures are worked out when the page opens and when the period changes.
  Filters, pages and opening a card only work on what was loaded.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{LocalTime, Monitoring}
  alias Zahlungs.Organizations.Organization

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Monitoring",
       per_page: @per_page,
       days: 30,
       status: "active",
       quick: "",
       search: "",
       page: 1,
       open: MapSet.new()
     )
     |> load()}
  end

  @impl true
  def handle_event("period", %{"days" => days}, socket) do
    {:noreply, socket |> assign(:days, period(days)) |> load()}
  end

  def handle_event("filter", %{"status" => status, "search" => search}, socket) do
    {:noreply, socket |> assign(status: status, search: search, page: 1) |> refresh()}
  end

  def handle_event("quick", %{"quick" => quick}, socket) do
    {:noreply, socket |> assign(quick: quick, page: 1) |> refresh()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    {:noreply, socket |> assign(:page, to_integer(to) || 1) |> refresh()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case to_integer(id) do
      nil -> {:noreply, socket}
      id -> {:noreply, update(socket, :open, &toggle(&1, id))}
    end
  end

  defp load(socket) do
    socket |> assign(:overview, Monitoring.overview(socket.assigns.days)) |> refresh()
  end

  # A page that no longer exists after filtering falls back to the last one.
  defp refresh(socket) do
    %{overview: overview, status: status, quick: quick, search: search} = socket.assigns
    rows = Monitoring.filter(overview.rows, status: status, quick: quick, search: search)
    total = length(rows)
    page = socket.assigns.page |> max(1) |> min(max(1, ceil(total / @per_page)))

    assign(socket,
      total: total,
      page: page,
      visible: Enum.slice(rows, (page - 1) * @per_page, @per_page)
    )
  end

  defp period(days) when days in [7, "7"], do: 7
  defp period(_days), do: 30

  # Events sent with JS.push arrive as numbers, those from phx-value as text.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp toggle(open, id) do
    if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)
  end

  defp quick_filters do
    [
      {"", "Semua"},
      {"quiet", "Sepi/Tidur"},
      {"billing", "Tagihan"},
      {"problems", "Masalah layanan"}
    ]
  end

  defp status_label("pending"), do: "Menunggu"
  defp status_label("active"), do: "Aktif"
  defp status_label("suspended"), do: "Ditangguhkan"
  defp status_label("rejected"), do: "Ditolak"

  defp activity_label(:active), do: "Aktif"
  defp activity_label(:quiet), do: "Sepi"
  defp activity_label(:asleep), do: "Tidur"
  defp activity_label(:never), do: "Belum pernah"

  defp activity_class(:active), do: "bg-green-100 text-green-700"
  defp activity_class(:quiet), do: "bg-yellow-100 text-yellow-800"
  defp activity_class(:asleep), do: "bg-red-100 text-red-700"
  defp activity_class(:never), do: "bg-gray-200 text-gray-700"

  defp billing_badge(:overdue), do: {"Tagihan lewat", "bg-red-100 text-red-700"}
  defp billing_badge(:due_soon), do: {"Segera jatuh tempo", "bg-yellow-100 text-yellow-800"}
  defp billing_badge(:unrecorded), do: {"Tagihan belum dicatat", "bg-gray-200 text-gray-700"}
  defp billing_badge(_billing), do: nil

  # Only what is above zero, for a row or a store's row.
  defp problems(row) do
    for {label, count} <- [
          {"Tertahan", row.stuck},
          {"Perlu dikembalikan", row.refunds_due},
          {"Menunggu keputusan", row.in_review},
          {"Saldo minus", Map.get(row, :negative_deposits, 0)}
        ],
        count > 0 do
      "#{label} #{count}"
    end
  end

  defp time_text(nil), do: "—"
  defp time_text(%NaiveDateTime{} = local), do: Calendar.strftime(local, "%d %b %Y %H:%M")

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp figure(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-200 p-3">
      <p class="text-xs text-gray-600">{@label}</p>
      <p class="mt-1 break-words font-semibold">{@value}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-xs text-gray-500">{@label}</dt>
      <dd class="break-words text-sm">{@value}</dd>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :class, :string, required: true

  defp badge(assigns) do
    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-xs", @class]}>{@text}</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Monitoring
      <:subtitle>
        Keadaan semua organisasi yang terdaftar. Hanya ringkasan, tanpa isi transaksi.
      </:subtitle>
    </.header>

    <p class="mt-2 text-xs text-gray-500">
      Angka per {Calendar.strftime(LocalTime.to_local(@overview.at), "%H.%M")}. Muat ulang halaman untuk memperbarui.
    </p>

    <div class="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-5">
      <.figure label="Organisasi aktif" value={to_string(@overview.summary.active_organizations)} />
      <.figure label="Omzet barang" value={format_price(@overview.summary.sales_total)} />
      <.figure label="Omzet layanan" value={format_price(@overview.summary.services_total)} />
      <.figure label="Tagihan lewat" value={to_string(@overview.summary.overdue)} />
      <.figure label="Organisasi bermasalah" value={to_string(@overview.summary.with_problems)} />
    </div>

    <div class="mt-4 flex flex-wrap gap-2" role="group" aria-label="Periode">
      <button
        :for={days <- [7, 30]}
        type="button"
        phx-click={JS.push("period", value: %{days: days})}
        aria-pressed={to_string(@days == days)}
        class={["chip", @days == days && "chip-active"]}
      >
        {days} hari
      </button>
    </div>

    <form phx-change="filter" phx-submit="filter" class="mt-3 flex flex-wrap items-end gap-2">
      <label class="text-xs text-gray-600">
        Status
        <select name="status" class="form-control">
          <option value="" selected={@status == ""}>Semua status</option>
          <option
            :for={status <- Organization.statuses()}
            value={status}
            selected={@status == status}
          >
            {status_label(status)}
          </option>
        </select>
      </label>
      <label class="min-w-0 flex-1 text-xs text-gray-600">
        Cari nama organisasi
        <input
          type="search"
          name="search"
          value={@search}
          phx-debounce="300"
          autocomplete="off"
          class="form-control"
        />
      </label>
    </form>

    <div class="mt-3 flex flex-wrap gap-2" role="group" aria-label="Saring cepat">
      <button
        :for={{value, label} <- quick_filters()}
        type="button"
        phx-click="quick"
        phx-value-quick={value}
        aria-pressed={to_string(@quick == value)}
        class={["chip", @quick == value && "chip-active"]}
      >
        {label}
      </button>
    </div>

    <div class="mt-4 space-y-4">
      <div
        :for={row <- @visible}
        id={"monitoring-#{row.organization.id}"}
        class="rounded-lg border border-gray-200 p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="min-w-0 break-words">
            <p class="font-semibold">{row.organization.name}</p>
            <p class="text-sm text-gray-600">
              {row.owner_email || "—"}
              <span :if={row.organization.phone}>· {row.organization.phone}</span>
            </p>
          </div>
          <div class="flex flex-wrap gap-1">
            <.badge
              :if={row.organization.status != "active"}
              text={status_label(row.organization.status)}
              class="bg-gray-200 text-gray-700"
            />
            <.badge text={activity_label(row.activity)} class={activity_class(row.activity)} />
            <.badge
              :if={billing_badge(row.billing)}
              text={elem(billing_badge(row.billing), 0)}
              class={elem(billing_badge(row.billing), 1)}
            />
            <.badge :for={problem <- problems(row)} text={problem} class="bg-red-100 text-red-700" />
          </div>
        </div>

        <dl class="mt-3 grid grid-cols-2 gap-3 lg:grid-cols-5">
          <.fact
            label="Transaksi terakhir"
            value={time_text(LocalTime.to_local(row.last_transaction_at))}
          />
          <.fact label="Login terakhir" value={time_text(LocalTime.to_local(row.last_login_at))} />
          <.fact
            label="Omzet barang"
            value={"#{format_price(row.sales_total)} · #{row.sales_count} transaksi"}
          />
          <.fact
            label="Omzet layanan"
            value={"#{format_price(row.services_total)} · #{row.services_count} transaksi"}
          />
          <.fact label="Shift buka" value={to_string(row.open_shifts)} />
        </dl>

        <div class="mt-3 flex flex-wrap items-center justify-between gap-2">
          <p :if={row.quiet_stores > 0} class="text-sm text-gray-600">
            {row.quiet_stores} dari {row.active_stores} cabang sepi
          </p>
          <button
            type="button"
            phx-click={JS.push("toggle", value: %{id: row.organization.id})}
            aria-expanded={to_string(MapSet.member?(@open, row.organization.id))}
            class="chip ml-auto"
          >
            {if MapSet.member?(@open, row.organization.id), do: "Tutup cabang", else: "Lihat cabang"}
          </button>
        </div>

        <div :if={MapSet.member?(@open, row.organization.id)} class="mt-3 border-t border-gray-100 pt-3">
          <p :if={row.stores == []} class="text-sm text-gray-500">Belum ada cabang.</p>

          <div :for={store <- row.stores} class="border-b border-gray-100 py-3 last:border-b-0">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <p class="min-w-0 break-words text-sm font-medium">{store.name} ({store.code})</p>
              <div class="flex flex-wrap gap-1">
                <.badge :if={!store.active} text="Nonaktif" class="bg-gray-200 text-gray-700" />
                <.badge
                  :if={store.activity}
                  text={activity_label(store.activity)}
                  class={activity_class(store.activity)}
                />
                <.badge
                  :for={problem <- problems(store)}
                  text={problem}
                  class="bg-red-100 text-red-700"
                />
              </div>
            </div>
            <dl class="mt-2 grid grid-cols-2 gap-3 lg:grid-cols-5">
              <.fact
                label="Transaksi terakhir"
                value={time_text(Monitoring.local_time(store, store.last_transaction_at))}
              />
              <.fact
                label="Login terakhir"
                value={time_text(Monitoring.local_time(store, store.last_login_at))}
              />
              <.fact
                label="Omzet barang"
                value={"#{format_price(store.sales_total)} · #{store.sales_count} transaksi"}
              />
              <.fact
                label="Omzet layanan"
                value={"#{format_price(store.services_total)} · #{store.services_count} transaksi"}
              />
              <.fact label="Shift buka" value={to_string(store.open_shifts)} />
            </dl>
          </div>

          <div :if={row.deposits != []} class="mt-3">
            <p class="text-sm font-medium">Akun deposit</p>
            <div
              :for={deposit <- row.deposits}
              class="mt-1 flex flex-wrap justify-between gap-2 text-sm"
            >
              <span class="min-w-0 break-words">{deposit.name}</span>
              <span class={Decimal.negative?(deposit.balance) && "font-medium text-red-700"}>
                {format_price(deposit.balance)}
              </span>
            </div>
          </div>
        </div>
      </div>

      <p :if={@visible == []} class="text-sm text-gray-500">Tidak ada organisasi yang cocok.</p>
    </div>

    <.pagination page={@page} per_page={@per_page} total={@total} noun="organisasi" />
    """
  end
end
