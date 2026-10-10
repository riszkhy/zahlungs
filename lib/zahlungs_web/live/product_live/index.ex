defmodule ZahlungsWeb.ProductLive.Index do
  @moduledoc """
  Admin product management (CRUD). Access is restricted to admins via the
  `:ensure_admin` on_mount in the router's admin live_session.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Catalog
  alias Zahlungs.Catalog.Product

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(search: "", category_id: "", active_filter: "", scanning: false)
     |> assign(:category_options, Catalog.category_options())
     |> load_products()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Product Management")
    |> assign(:product, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Product")
    |> assign(:product, %Product{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Product")
    |> assign(:product, Catalog.get_product!(socket.assigns.current_scope, id))
  end

  @impl true
  def handle_event("filter", %{"search" => search} = params, socket) do
    {:noreply,
     socket
     |> assign(
       search: search,
       category_id: params["category_id"] || "",
       active_filter: params["active"] || ""
     )
     |> load_products()}
  end

  # Hardware scanner sends the code + Enter (form submit); route it through scan.
  def handle_event("scan", %{"search" => code}, socket) do
    handle_event("scan", %{"q" => code}, socket)
  end

  # Camera hook pushes `%{"q" => code}`. Use it as the search term (SKU/barcode)
  # and beep on hit/miss, like the cashier and catalog screens.
  def handle_event("scan", %{"q" => code}, socket) do
    socket = socket |> assign(:search, String.trim(code)) |> load_products()

    if socket.assigns.products == [] do
      {:noreply,
       socket
       |> push_event("beep", %{type: "error"})
       |> put_flash(:error, "Produk dengan kode \"#{code}\" tidak ditemukan.")}
    else
      {:noreply, push_event(socket, "beep", %{type: "ok"})}
    end
  end

  def handle_event("toggle_scan", _params, socket) do
    {:noreply, assign(socket, :scanning, not socket.assigns.scanning)}
  end

  def handle_event("camera_unsupported", _params, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(
       :error,
       "Camera scanning isn't supported on this browser. Use a USB scanner or type the code."
     )}
  end

  def handle_event("camera_error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(:error, "Could not start the camera: #{message}")}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    product = Catalog.get_product!(socket.assigns.current_scope, id)
    {:ok, _} = Catalog.set_product_active(product, !product.active)
    {:noreply, load_products(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    product = Catalog.get_product!(socket.assigns.current_scope, id)
    {:ok, _} = Catalog.delete_product(product)

    {:noreply,
     socket
     |> put_flash(:info, "Product deleted")
     |> load_products()}
  end

  @impl true
  def handle_info({ZahlungsWeb.ProductLive.FormComponent, {:saved, _product}}, socket) do
    {:noreply, load_products(socket)}
  end

  defp load_products(socket) do
    opts = [
      search: socket.assigns.search,
      category_id: parse_category(socket.assigns.category_id),
      active: parse_active(socket.assigns.active_filter)
    ]

    assign(socket, :products, Catalog.list_products(socket.assigns.current_scope, opts))
  end

  defp parse_active("true"), do: true
  defp parse_active("false"), do: false
  defp parse_active(_), do: nil

  defp parse_category(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_category(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Product Management
      <:subtitle>Kelola produk (khusus admin)</:subtitle>
      <:actions>
        <.link patch={~p"/categories"} class="btn btn-sm btn-link">Categories</.link>
        <.link patch={~p"/products/new"}>
          <.button>New Product</.button>
        </.link>
      </:actions>
    </.header>

    <div id="products-beeper" phx-hook="Beeper" class="hidden"></div>

    <form phx-change="filter" phx-submit="scan" class="mt-6 flex flex-wrap gap-3 items-end">
      <input
        type="text"
        name="search"
        value={@search}
        placeholder="Search name / SKU / barcode..."
        phx-debounce="300"
        autocomplete="off"
        class="form-control max-w-xs"
      />
      <select name="category_id" class="form-control max-w-xs">
        <option value="">All categories</option>
        <option :for={{name, id} <- @category_options} value={id} selected={to_string(id) == @category_id}>
          {name}
        </option>
      </select>
      <select name="active" class="form-control max-w-[10rem]">
        <option value="" selected={@active_filter == ""}>All status</option>
        <option value="true" selected={@active_filter == "true"}>Active</option>
        <option value="false" selected={@active_filter == "false"}>Inactive</option>
      </select>
      <button type="button" phx-click="toggle_scan" class="text-sm text-blue-600 hover:underline">
        {if @scanning, do: "■ Stop camera", else: "📷 Scan barcode"}
      </button>
    </form>

    <div :if={@scanning} class="mt-2">
      <video
        id="product-search-scanner"
        phx-hook="BarcodeScanner"
        phx-update="ignore"
        autoplay
        muted
        class="w-full max-w-xs rounded border border-gray-300 bg-black aspect-video"
      >
      </video>
      <p data-scan-status class="mt-1 text-xs text-gray-400">Point the camera at a barcode.</p>
    </div>

    <.table id="products" rows={@products}>
      <:col :let={product} label="SKU">{product.sku}</:col>
      <:col :let={product} label="Name">{product.name}</:col>
      <:col :let={product} label="Category">{product.category && product.category.name}</:col>
      <:col :let={product} label="Price">{format_money(product.price)}</:col>
      <:col :let={product} label="Stock">{product.stock}</:col>
      <:col :let={product} label="Status">
        <span class={if product.active, do: "text-green-600", else: "text-gray-400"}>
          {if product.active, do: "Active", else: "Inactive"}
        </span>
      </:col>
      <:action :let={product}>
        <.link patch={~p"/products/#{product}/edit"}>Edit</.link>
      </:action>
      <:action :let={product}>
        <.link phx-click={JS.push("toggle_active", value: %{id: product.id})}>
          {if product.active, do: "Deactivate", else: "Activate"}
        </.link>
      </:action>
      <:action :let={product}>
        <.link
          phx-click={JS.push("delete", value: %{id: product.id})}
          data-confirm="Delete this product? It will be hidden but kept for history."
        >
          Delete
        </.link>
      </:action>
    </.table>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="product-modal"
      show
      on_cancel={JS.patch(~p"/products")}
    >
      <.live_component
        module={ZahlungsWeb.ProductLive.FormComponent}
        id={@product.id || :new}
        title={@page_title}
        action={@live_action}
        product={@product}
        scope={@current_scope}
        patch={~p"/products"}
      />
    </.modal>
    """
  end
end
