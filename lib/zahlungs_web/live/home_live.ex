defmodule ZahlungsWeb.HomeLive do
  @moduledoc """
  Home: the first screen after logging in. A greeting, the cashier's shift (is
  one open, and what it has sold), the store's figures for today, and shortcuts.

  Every figure is a link to the screen behind it where the user may open that
  screen — reports and category management are for admins.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, LocalTime, Sales, Shifts, Stores}

  @low_stock_threshold 5

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    summary = Sales.sales_summary_today(scope)
    low_stock_products = Catalog.list_low_stock_products(scope, @low_stock_threshold)

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:greeting, greeting(LocalTime.now(scope.store).hour))
     |> assign(:store_label, (scope.store && scope.store.name) || "Semua toko")
     |> assign(:admin?, socket.assigns.current_user.role == "admin")
     |> assign(:active_products, Catalog.count_products(scope, active: true))
     |> assign(:low_stock_products, low_stock_products)
     |> assign(:low_stock, length(low_stock_products))
     |> assign(:low_stock_threshold, @low_stock_threshold)
     |> assign(:categories, length(Catalog.list_categories()))
     |> assign(:sales_today_total, ZahlungsWeb.CoreComponents.format_money(summary.total))
     |> assign(:sales_today_count, summary.count)
     |> assign_shift()}
  end

  # The user's own open shift, wherever it is, and what it has sold so far.
  defp assign_shift(socket) do
    case Shifts.current_shift(socket.assigns.current_user) do
      nil ->
        assign(socket, shift: nil, shift_store: nil, shift_summary: nil, shift_age: nil)

      shift ->
        age = NaiveDateTime.diff(NaiveDateTime.utc_now(), shift.opened_at)

        assign(socket,
          shift: shift,
          shift_store: Stores.get_store!(shift.store_id),
          shift_summary: Shifts.shift_summary(shift),
          shift_age: age
        )
    end
  end

  @doc "The greeting for an hour of the shop's day (0-23)."
  def greeting(hour) when hour in 5..10, do: "Selamat pagi"
  def greeting(hour) when hour in 11..14, do: "Selamat siang"
  def greeting(hour) when hour in 15..17, do: "Selamat sore"
  def greeting(_hour), do: "Selamat malam"

  @doc """
  How long something has lasted, in words: `baru saja`, `45 mnt`,
  `3 jam 40 mnt`, `2 hari 5 jam` (minutes are dropped once it is days).
  """
  def duration_label(seconds) when seconds < 60, do: "baru saja"

  def duration_label(seconds) do
    minutes = div(seconds, 60)
    hours = div(minutes, 60)

    case {div(hours, 24), rem(hours, 24), rem(minutes, 60)} do
      {0, 0, m} -> "#{m} mnt"
      {0, h, 0} -> "#{h} jam"
      {0, h, m} -> "#{h} jam #{m} mnt"
      {d, 0, _} -> "#{d} hari"
      {d, h, _} -> "#{d} hari #{h} jam"
    end
  end

  @months ~w(Jan Feb Mar Apr Mei Jun Jul Agu Sep Okt Nov Des)

  # The person's name, or their email when none was given.
  defp display_name(%{name: name, email: email}) do
    case name && String.trim(name) do
      value when value in [nil, ""] -> email
      value -> value
    end
  end

  # The time the shift opened; with the date as well when that was not today,
  # so a shift left open overnight isn't mistaken for this morning's.
  defp opened_at(shift, store) do
    local = LocalTime.to_local(shift.opened_at, store)
    time = Calendar.strftime(local, "%H:%M")

    if NaiveDateTime.to_date(local) == LocalTime.today(store) do
      time
    else
      "#{local.day} #{Enum.at(@months, local.month - 1)} #{time}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@greeting}, {display_name(@current_user)}
      <:subtitle>{@store_label}</:subtitle>
    </.header>

    <section
      id="shift-card"
      class={[
        "mt-6 rounded-lg border p-5",
        @shift && "border-green-300 bg-green-50",
        !@shift && "border-gray-200 bg-gray-50"
      ]}
    >
      <div :if={@shift}>
        <p class="flex items-center gap-2 text-sm font-medium text-green-800">
          <span class="h-2.5 w-2.5 rounded-full bg-green-600" aria-hidden="true"></span>
          Shift terbuka sejak {opened_at(@shift, @shift_store)} ({duration_label(@shift_age)}) · {@shift_store.name}
        </p>
        <p class="mt-3 text-sm text-gray-600">Penjualan Anda di shift ini</p>
        <p class="text-2xl font-semibold text-gray-800">
          {format_money(@shift_summary.sales_total)}
          <span class="text-sm font-normal text-gray-500">· {@shift_summary.transactions} transaksi</span>
        </p>
        <div class="mt-4 flex flex-wrap items-center gap-3">
          <.link navigate={~p"/cashier"} class="btn btn-primary inline-flex items-center">
            Lanjut berjualan
          </.link>
          <.link navigate={~p"/shifts/#{@shift.id}"} class="chip">Detail shift</.link>
        </div>
      </div>

      <div :if={is_nil(@shift) and @current_scope.store}>
        <p class="font-medium text-gray-800">Belum ada shift</p>
        <p class="mt-1 text-sm text-gray-600">
          Buka shift dulu (isi kas awal) untuk mulai berjualan.
        </p>
        <.link navigate={~p"/cashier"} class="btn btn-primary mt-4 inline-flex items-center">
          Buka shift
        </.link>
      </div>

      <div :if={is_nil(@shift) and is_nil(@current_scope.store)}>
        <p class="font-medium text-gray-800">Belum ada shift</p>
        <p class="mt-1 text-sm text-gray-600">
          Pilih toko di bilah atas untuk membuka shift.
        </p>
      </div>
    </section>

    <div class="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat_card
        id="card-products"
        label="Produk aktif"
        value={@active_products}
        accent="text-blue-600"
        navigate={if @admin?, do: ~p"/products", else: ~p"/catalog"}
      />
      <.stat_card
        id="card-low-stock"
        label="Stok menipis"
        value={@low_stock}
        accent="text-amber-600"
        hint={"stok ≤ #{@low_stock_threshold} unit"}
        navigate={if @admin?, do: ~p"/reports/stock"}
      />
      <.stat_card
        id="card-categories"
        label="Kategori"
        value={@categories}
        accent="text-gray-700"
        navigate={if @admin?, do: ~p"/categories"}
      />
      <.stat_card
        id="card-sales"
        label={if @current_scope.store, do: "Penjualan toko hari ini", else: "Penjualan semua toko hari ini"}
        value={@sales_today_total}
        accent="text-green-600"
        hint={"#{@sales_today_count} transaksi"}
        navigate={~p"/sales"}
      />
    </div>

    <div :if={@admin? and @low_stock_products != []} class="mt-8 rounded-lg border border-amber-200 bg-amber-50 p-4">
      <h3 class="font-semibold text-amber-800">Stok menipis — perlu restock</h3>
      <ul class="mt-2 divide-y divide-amber-100">
        <li :for={product <- @low_stock_products} class="flex justify-between py-1 text-sm">
          <span class="text-gray-700">{product.name} <span class="text-gray-400">({product.sku})</span></span>
          <span class="font-medium text-amber-700">sisa {product.stock}</span>
        </li>
      </ul>
      <.link navigate={~p"/products"} class="mt-3 inline-block text-sm text-blue-600 hover:underline">
        Kelola produk →
      </.link>
    </div>

    <h3 class="mt-8 font-semibold text-gray-700">Pintasan</h3>
    <div class="mt-3 flex flex-wrap gap-2">
      <.link navigate={~p"/catalog"} class="chip">Katalog</.link>
      <.link navigate={~p"/users/settings"} class="chip">Profil</.link>
      <.link :if={@admin?} navigate={~p"/products"} class="chip">Kelola produk</.link>
      <.link :if={@admin?} navigate={~p"/categories"} class="chip">Kelola kategori</.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: "text-gray-800"
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil, doc: "where the card leads; a plain card when nil"

  defp stat_card(%{navigate: nil} = assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-gray-200 p-5 shadow-sm">
      <.stat_body label={@label} value={@value} accent={@accent} hint={@hint} />
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="block rounded-lg border border-gray-200 p-5 shadow-sm transition hover:border-green-600 hover:shadow"
    >
      <.stat_body label={@label} value={@value} accent={@accent} hint={@hint} />
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, required: true
  attr :hint, :string, default: nil

  defp stat_body(assigns) do
    ~H"""
    <p class="text-sm text-gray-500">{@label}</p>
    <p class={["mt-2 text-3xl font-semibold", @accent]}>{@value}</p>
    <p :if={@hint} class="mt-1 text-xs text-gray-500">{@hint}</p>
    """
  end
end
