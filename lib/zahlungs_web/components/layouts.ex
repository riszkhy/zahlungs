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
  Renders the navigation user menu shown in the root layout.
  """
  attr :current_user, :map, default: nil
  attr :current_scope, :map, default: nil

  def user_menu(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center gap-2 md:gap-4 text-sm font-medium py-3 md:py-0">
      <%= if @current_user do %>
        <.link href={~p"/home"} class="text-white/90 hover:text-white hover:underline">Home</.link>
        <.link href={~p"/cashier"} class="text-white/90 hover:text-white hover:underline">Cashier</.link>
        <.link href={~p"/catalog"} class="text-white/90 hover:text-white hover:underline">Catalog</.link>
        <.link href={~p"/sales"} class="text-white/90 hover:text-white hover:underline">Sales</.link>
        <.link href={~p"/shifts"} class="text-white/90 hover:text-white hover:underline">Shifts</.link>
        <.link :if={@current_user.role == "admin"} href={~p"/products"} class="text-white/90 hover:text-white hover:underline">
          Products
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/categories"} class="text-white/90 hover:text-white hover:underline">
          Categories
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/admin/users"} class="text-white/90 hover:text-white hover:underline">
          Users
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/admin/stores"} class="text-white/90 hover:text-white hover:underline">
          Stores
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/admin/suppliers"} class="text-white/90 hover:text-white hover:underline">
          Suppliers
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/reports/sales"} class="text-white/90 hover:text-white hover:underline">
          Reports
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/reports/stock"} class="text-white/90 hover:text-white hover:underline">
          Stock
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/reports/consignment"} class="text-white/90 hover:text-white hover:underline">
          Consignment
        </.link>
        <.store_switcher :if={@current_scope} scope={@current_scope} />
        <.link href={~p"/users/settings"} class="text-white/90 hover:text-white hover:underline">Profile</.link>
        <span class="hidden md:inline text-white/70">{@current_user.email}</span>
        <.form for={%{}} action={~p"/users/log_out"} method="delete" class="inline">
          <button type="submit" class="text-white/90 hover:text-white hover:underline">Log out</button>
        </.form>
      <% else %>
        <.link href={~p"/users/log_in"} class="text-white/90 hover:text-white hover:underline">Log in</.link>
      <% end %>
    </div>
    """
  end
end
