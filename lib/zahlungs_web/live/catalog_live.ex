defmodule ZahlungsWeb.CatalogLive do
  @moduledoc """
  Read-only product catalog: browse active products with search, category and
  in-stock filters, plus simple pagination. Available to any authenticated user.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Catalog

  @per_page 12

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Catalog", search: "", category_id: "", in_stock: false, page: 1)
     |> assign(:category_options, Catalog.category_options())
     |> load_products()}
  end

  @impl true
  def handle_event("filter", %{"search" => search} = params, socket) do
    {:noreply,
     socket
     |> assign(
       search: search,
       category_id: params["category_id"] || "",
       in_stock: params["in_stock"] == "true",
       page: 1
     )
     |> load_products()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    page = max(1, min(socket.assigns.total_pages, String.to_integer(to)))
    {:noreply, socket |> assign(:page, page) |> load_products()}
  end

  defp load_products(socket) do
    filters = [
      search: socket.assigns.search,
      category_id: parse_category(socket.assigns.category_id),
      in_stock: socket.assigns.in_stock,
      active: true
    ]

    total = Catalog.count_products(filters)
    total_pages = max(1, ceil(total / @per_page))
    page = min(socket.assigns.page, total_pages)

    products =
      Catalog.list_products(filters ++ [limit: @per_page, offset: (page - 1) * @per_page])

    assign(socket, products: products, total: total, total_pages: total_pages, page: page)
  end

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
      Catalog
      <:subtitle>Telusuri produk yang tersedia</:subtitle>
    </.header>

    <form phx-change="filter" phx-submit="filter" class="mt-6 flex flex-wrap gap-3 items-center">
      <input
        type="text"
        name="search"
        value={@search}
        placeholder="Search name / SKU..."
        phx-debounce="300"
        class="form-control max-w-xs"
      />
      <select name="category_id" class="form-control max-w-xs">
        <option value="">All categories</option>
        <option :for={{name, id} <- @category_options} value={id} selected={to_string(id) == @category_id}>
          {name}
        </option>
      </select>
      <label class="flex items-center gap-2 text-sm text-gray-600">
        <input type="hidden" name="in_stock" value="false" />
        <input type="checkbox" name="in_stock" value="true" checked={@in_stock} class="form-checkbox" />
        In stock only
      </label>
    </form>

    <p class="mt-4 text-sm text-gray-500">{@total} product(s) found</p>

    <div :if={@products == []} class="mt-6 text-gray-500">No products match your filters.</div>

    <div class="mt-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <div
        :for={product <- @products}
        class="rounded-lg border border-gray-200 p-4 shadow-sm hover:shadow transition"
      >
        <div class="flex items-start justify-between gap-2">
          <h3 class="font-semibold text-gray-800">{product.name}</h3>
          <span class={[
            "text-xs px-2 py-0.5 rounded-full whitespace-nowrap",
            (product.stock > 0 && "bg-green-100 text-green-700") || "bg-red-100 text-red-700"
          ]}>
            {if product.stock > 0, do: "Stock: #{product.stock}", else: "Out of stock"}
          </span>
        </div>
        <p class="mt-1 text-xs text-gray-400">SKU: {product.sku}</p>
        <p class="mt-1 text-xs text-gray-500">
          {(product.category && product.category.name) || "Uncategorized"}
        </p>
        <p class="mt-3 text-lg font-medium text-blue-600">{format_money(product.price)}</p>
      </div>
    </div>

    <div :if={@total_pages > 1} class="mt-8 flex items-center justify-center gap-4">
      <.button
        phx-click={JS.push("page", value: %{to: @page - 1})}
        disabled={@page <= 1}
        class="!bg-gray-200 !text-gray-700"
      >
        Prev
      </.button>
      <span class="text-sm text-gray-600">Page {@page} of {@total_pages}</span>
      <.button
        phx-click={JS.push("page", value: %{to: @page + 1})}
        disabled={@page >= @total_pages}
        class="!bg-gray-200 !text-gray-700"
      >
        Next
      </.button>
    </div>
    """
  end
end
