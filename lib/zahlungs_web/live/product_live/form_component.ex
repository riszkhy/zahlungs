defmodule ZahlungsWeb.ProductLive.FormComponent do
  use ZahlungsWeb, :live_component

  alias Zahlungs.Catalog

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>{@title}</.header>

      <.form
        for={@form}
        id="product-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <%= if @action == :edit do %>
          <.input field={@form[:sku]} type="text" label="SKU" readonly />
        <% else %>
          <div class="mt-4">
            <span class="block text-gray-600 dark:text-gray-200 text-sm font-medium mb-1">SKU</span>
            <p class="text-sm text-gray-500">
              Auto-generated on save: 3 category consonants + counter (e.g. <code>DRN001</code>).
            </p>
          </div>
        <% end %>

        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:barcode]} type="text" label="Barcode" />
        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <.input
            field={@form[:purchase_price]}
            type="number"
            label="Purchase price (Harga Beli)"
            step="0.01"
            min="0"
          />
          <.input field={@form[:margin_percent]} type="number" label="Margin (%)" step="0.01" min="0" />
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <.input
            field={@form[:price]}
            type="number"
            label="Selling price (auto from purchase + margin)"
            step="0.01"
            min="0"
            required
          />
          <.input field={@form[:stock]} type="number" label="Stock" min="0" required />
        </div>

        <.input
          field={@form[:category_id]}
          type="select"
          label="Category"
          prompt="— none —"
          options={@category_options}
        />
        <.input field={@form[:image_url]} type="text" label="Image URL" />
        <.input field={@form[:active]} type="checkbox" label="Active" />

        <div class="mt-6">
          <.button phx-disable-with="Saving...">Save Product</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{product: product} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:category_options, Catalog.category_options())
     |> assign(:form, to_form(Catalog.change_product(product)))}
  end

  @impl true
  def handle_event("validate", %{"product" => params} = unsigned, socket) do
    params = recalculate(params, unsigned["_target"])
    changeset = Catalog.change_product(socket.assigns.product, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"product" => params}, socket) do
    save_product(socket, socket.assigns.action, params)
  end

  # Two-way pricing:
  #   * editing purchase price or margin  -> recompute the selling price
  #   * editing the selling price directly -> recompute the margin
  # Both require a positive purchase price; otherwise values are left as typed.
  defp recalculate(params, ["product", "price"]), do: maybe_compute_margin(params)
  defp recalculate(params, ["product", "purchase_price"]), do: maybe_compute_price(params)
  defp recalculate(params, ["product", "margin_percent"]), do: maybe_compute_price(params)
  defp recalculate(params, _target), do: params

  defp maybe_compute_price(params) do
    if positive_number?(params["purchase_price"]) do
      price = Catalog.compute_price(params["purchase_price"], params["margin_percent"])
      Map.put(params, "price", Decimal.to_string(price))
    else
      params
    end
  end

  defp maybe_compute_margin(params) do
    if positive_number?(params["purchase_price"]) do
      margin = Catalog.compute_margin(params["price"], params["purchase_price"])
      Map.put(params, "margin_percent", Decimal.to_string(margin))
    else
      params
    end
  end

  defp positive_number?(value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {d, _} -> Decimal.gt?(d, Decimal.new(0))
      :error -> false
    end
  end

  defp positive_number?(_), do: false

  defp save_product(socket, :edit, params) do
    case Catalog.update_product(socket.assigns.product, params) do
      {:ok, product} ->
        notify_parent({:saved, product})

        {:noreply,
         socket
         |> put_flash(:info, "Product updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_product(socket, :new, params) do
    case Catalog.create_product(params) do
      {:ok, product} ->
        notify_parent({:saved, product})

        {:noreply,
         socket
         |> put_flash(:info, "Product created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
