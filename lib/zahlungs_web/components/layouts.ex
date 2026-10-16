defmodule ZahlungsWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use ZahlungsWeb, :controller` and
  `use ZahlungsWeb, :live_view`.
  """
  use ZahlungsWeb, :html

  embed_templates "layouts/*"

  @doc """
  The store the user is working in. An admin gets a switcher (any active store,
  or all of them); a cashier just sees the name of their store.
  """
  attr :scope, :map, required: true

  def store_switcher(assigns) do
    assigns = assign(assigns, :admin?, Zahlungs.Scope.admin?(assigns.scope))

    ~H"""
    <.form :if={@admin?} for={%{}} action={~p"/stores/select"} method="post" class="inline">
      <input type="hidden" name="return_to" value="" />
      <select
        name="store_id"
        aria-label="Toko aktif"
        onchange="this.form.return_to.value = window.location.pathname; this.form.submit()"
        class="rounded border-0 bg-white/15 py-1 pl-2 pr-7 text-sm text-white focus:ring-1 focus:ring-white"
      >
        <option value="all" selected={is_nil(@scope.store)} class="text-gray-800">Semua toko</option>
        <option
          :for={store <- Zahlungs.Stores.list_active_stores()}
          value={store.id}
          selected={@scope.store && @scope.store.id == store.id}
          class="text-gray-800"
        >
          {store.name}
        </option>
      </select>
    </.form>
    <span :if={not @admin? and @scope.store} class="rounded bg-white/15 px-2 py-1 text-white">
      {@scope.store.name}
    </span>
    """
  end

  @doc """
  The cashier's everyday screens, shown in the top bar from tablet width up.
  Admin and account links are in `menu_drawer/1`.
  """
  attr :current_user, :map, required: true

  def primary_nav(assigns) do
    ~H"""
    <nav id="primary-nav" class="hidden items-center gap-1 md:flex" aria-label="Utama">
      <.link :for={{label, path} <- primary_links(@current_user)} href={path} class="nav-tap">{label}</.link>
    </nav>
    """
  end

  # The platform operator has no point of sale, only the organizations page.
  defp primary_links(%{role: "superadmin"}), do: platform_links()
  defp primary_links(_user), do: cashier_links()

  defp platform_links, do: [{"Organisasi", ~p"/platform/organizations"}]

  @doc """
  The full menu, grouped, in a drawer that slides in from the right. Opened by
  the Menu button in the root layout (Alpine `open`).
  """
  attr :current_user, :map, required: true
  attr :current_scope, :map, default: nil

  def menu_drawer(assigns) do
    ~H"""
    <aside
      id="menu-drawer"
      x-show="open"
      x-cloak
      @keydown.escape.window="open = false"
      class="fixed inset-y-0 right-0 z-50 flex w-72 max-w-full flex-col overflow-y-auto bg-white text-gray-800 shadow-xl"
      aria-label="Menu"
    >
      <div class="flex items-center justify-between border-b border-gray-200 px-4 py-3">
        <span class="font-semibold">Menu</span>
        <button type="button" class="drawer-link !w-auto" @click="open = false">Tutup</button>
      </div>

      <.menu_group :if={@current_user.role == "superadmin"} title="Platform" links={platform_links()} />
      <.menu_group
        :if={@current_user.role != "superadmin"}
        title="Kasir"
        links={[{"Home", ~p"/home"} | cashier_links()]}
      />
      <.menu_group :if={@current_user.role == "admin"} title="Admin" links={admin_links()} />

      <div class="mt-auto border-t border-gray-200 px-2 py-3">
        <p class="px-3 text-xs font-semibold uppercase tracking-wide text-gray-500">Akun</p>
        <p class="truncate px-3 py-1 text-sm text-gray-500">{@current_user.email}</p>
        <.link :if={@current_user.role != "superadmin"} href={~p"/users/settings"} class="drawer-link">
          Profile
        </.link>
        <.form for={%{}} action={~p"/users/log_out"} method="delete">
          <button type="submit" class="drawer-link text-left text-red-700">Log out</button>
        </.form>
      </div>
    </aside>
    """
  end

  attr :title, :string, required: true
  attr :links, :list, required: true

  defp menu_group(assigns) do
    ~H"""
    <div class="px-2 py-3">
      <p class="px-3 text-xs font-semibold uppercase tracking-wide text-gray-500">{@title}</p>
      <.link :for={{label, path} <- @links} href={path} class="drawer-link">{label}</.link>
    </div>
    """
  end

  defp cashier_links do
    [
      {"Cashier", ~p"/cashier"},
      {"Layanan", ~p"/services"},
      {"Sales", ~p"/sales"},
      {"Shifts", ~p"/shifts"},
      {"Catalog", ~p"/catalog"}
    ]
  end

  defp admin_links do
    [
      {"Products", ~p"/products"},
      {"Categories", ~p"/categories"},
      {"Users", ~p"/admin/users"},
      {"Stores", ~p"/admin/stores"},
      {"Daftar Cabang", ~p"/admin/stores/register"},
      {"Riwayat login", ~p"/admin/logins"},
      {"Suppliers", ~p"/admin/suppliers"},
      {"Produk layanan", ~p"/admin/services"},
      {"Reports", ~p"/reports/sales"},
      {"Stock", ~p"/reports/stock"},
      {"Consignment", ~p"/reports/consignment"}
    ]
  end
end
