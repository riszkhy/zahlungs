defmodule ZahlungsWeb.CategoryLive.Index do
  @moduledoc """
  Admin category management (CRUD). Admin-only via the router's admin live_session.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Catalog
  alias Zahlungs.Catalog.Category

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_categories(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Categories")
    |> assign(:category, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Category")
    |> assign(:category, %Category{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Category")
    |> assign(:category, Catalog.get_category!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    category = Catalog.get_category!(id)
    {:ok, _} = Catalog.delete_category(category)

    {:noreply,
     socket
     |> put_flash(:info, "Category deleted")
     |> load_categories()}
  end

  @impl true
  def handle_info({ZahlungsWeb.CategoryLive.FormComponent, {:saved, _category}}, socket) do
    {:noreply, load_categories(socket)}
  end

  defp load_categories(socket) do
    assign(socket, :categories, Catalog.list_categories())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Categories
      <:subtitle>Kelola kategori produk (khusus admin)</:subtitle>
      <:actions>
        <.link patch={~p"/products"} class="btn btn-sm btn-link">Products</.link>
        <.link patch={~p"/categories/new"}>
          <.button>New Category</.button>
        </.link>
      </:actions>
    </.header>

    <.table id="categories" rows={@categories}>
      <:col :let={category} label="Name">{category.name}</:col>
      <:action :let={category}>
        <.link patch={~p"/categories/#{category}/edit"}>Edit</.link>
      </:action>
      <:action :let={category}>
        <.link
          phx-click={JS.push("delete", value: %{id: category.id})}
          data-confirm="Delete this category?"
        >
          Delete
        </.link>
      </:action>
    </.table>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="category-modal"
      show
      on_cancel={JS.patch(~p"/categories")}
    >
      <.live_component
        module={ZahlungsWeb.CategoryLive.FormComponent}
        id={@category.id || :new}
        title={@page_title}
        action={@live_action}
        category={@category}
        patch={~p"/categories"}
      />
    </.modal>
    """
  end
end
