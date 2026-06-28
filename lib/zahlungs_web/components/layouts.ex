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
    <div class="flex items-center space-x-1 text-sm">
      <%= if @current_user do %>
        <.link href={~p"/home"} class="btn btn-sm btn-link">Home</.link>
        <.link href={~p"/cashier"} class="btn btn-sm btn-link">Cashier</.link>
        <.link href={~p"/catalog"} class="btn btn-sm btn-link">Catalog</.link>
        <.link href={~p"/sales"} class="btn btn-sm btn-link">Sales</.link>
        <.link :if={@current_user.role == "admin"} href={~p"/products"} class="btn btn-sm btn-link">
          Products
        </.link>
        <.link :if={@current_user.role == "admin"} href={~p"/categories"} class="btn btn-sm btn-link">
          Categories
        </.link>
        <.link href={~p"/users/settings"} class="btn btn-sm btn-link">Profile</.link>
        <span class="hidden md:inline text-base-content text-opacity-60">
          {@current_user.email}
        </span>
        <.form for={%{}} action={~p"/users/log_out"} method="delete" class="inline">
          <button type="submit" class="btn btn-sm btn-link">Log out</button>
        </.form>
      <% else %>
        <.link href={~p"/users/register"} class="btn btn-sm btn-link">Register</.link>
        <.link href={~p"/users/log_in"} class="btn btn-sm btn-link">Log in</.link>
      <% end %>
    </div>
    """
  end
end
