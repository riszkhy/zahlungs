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
  Renders the navigation user menu shown in the root layout.
  """
  attr :current_user, :map, default: nil

  def user_menu(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-sm font-medium">
      <%= if @current_user do %>
        <.link href={~p"/home"} class="text-white/90 hover:text-white hover:underline">Home</.link>
        <.link href={~p"/cashier"} class="text-white/90 hover:text-white hover:underline">Cashier</.link>
        <.link href={~p"/catalog"} class="text-white/90 hover:text-white hover:underline">Catalog</.link>
        <.link href={~p"/sales"} class="text-white/90 hover:text-white hover:underline">Sales</.link>
        <.link :if={@current_user.role == "admin"} href={~p"/products"} class="text-white/90 hover:text-white hover:underline">
          Products
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/categories"} class="text-white/90 hover:text-white hover:underline">
          Categories
        </.link>
        <.link href={~p"/users/settings"} class="text-white/90 hover:text-white hover:underline">Profile</.link>
        <span class="hidden md:inline text-white/70">{@current_user.email}</span>
        <.form for={%{}} action={~p"/users/log_out"} method="delete" class="inline">
          <button type="submit" class="text-white/90 hover:text-white hover:underline">Log out</button>
        </.form>
      <% else %>
        <.link href={~p"/users/register"} class="text-white/90 hover:text-white hover:underline">Register</.link>
        <.link href={~p"/users/log_in"} class="text-white/90 hover:text-white hover:underline">Log in</.link>
      <% end %>
    </div>
    """
  end
end
