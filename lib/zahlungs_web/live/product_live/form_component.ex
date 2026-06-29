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
        <button
          type="button"
          id="barcode-scan-toggle"
          phx-click="toggle_barcode_scan"
          phx-target={@myself}
          class="mt-1 text-sm text-blue-600 hover:underline"
        >
          {if @scanning, do: "■ Stop camera", else: "📷 Scan barcode with camera"}
        </button>
        <div :if={@scanning} class="mt-2">
          <video
            id="product-barcode-scanner"
            phx-hook="BarcodeInput"
            phx-update="ignore"
            data-target={@form[:barcode].id}
            autoplay
            muted
            class="w-full max-w-xs rounded border border-gray-300 bg-black aspect-video"
          >
          </video>
          <p data-scan-status class="mt-1 text-xs text-gray-400">Point the camera at a barcode.</p>
        </div>

        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <.money_field field={@form[:purchase_price]} id="purchase-price-input" label="Purchase price (Harga Beli)" />
          <.input field={@form[:margin_percent]} type="number" label="Margin (%)" step="0.01" min="0" />
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <.money_field
            field={@form[:price]}
            id="selling-price-input"
            label="Selling price (auto from purchase + margin)"
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

  # A thousands-formatted money input (integer Rupiah). The visible value is
  # formatted client-side by the MoneyInput hook; the form submits the formatted
  # string and the server strips the separators (see strip_money/1).
  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp money_field(assigns) do
    ~H"""
    <div class="mt-4">
      <.label for={@id}>{@label}</.label>
      <input
        type="text"
        id={@id}
        name={@field.name}
        value={money_str(@field.value)}
        phx-hook="MoneyInput"
        phx-update="ignore"
        inputmode="numeric"
        class="form-control"
      />
      <.error :for={msg <- Enum.map(@field.errors, &translate_error/1)}>{msg}</.error>
    </div>
    """
  end

  # Renders any money value as a plain integer string (no separators/decimals)
  # for the initial input value.
  defp money_str(nil), do: ""
  defp money_str(""), do: ""

  defp money_str(%Decimal{} = d) do
    d |> Decimal.round(0) |> Decimal.to_integer() |> Integer.to_string()
  end

  defp money_str(n) when is_integer(n), do: Integer.to_string(n)

  defp money_str(s) when is_binary(s) do
    case s |> String.replace(".", "") |> Decimal.parse() do
      {d, _} -> money_str(d)
      :error -> ""
    end
  end

  @impl true
  def update(%{product: product} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:category_options, Catalog.category_options())
     |> assign_new(:scanning, fn -> false end)
     |> assign(:form, to_form(Catalog.change_product(product)))}
  end

  @impl true
  def handle_event("toggle_barcode_scan", _params, socket) do
    {:noreply, assign(socket, :scanning, not socket.assigns.scanning)}
  end

  @impl true
  def handle_event("validate", %{"product" => params} = unsigned, socket) do
    params = params |> strip_money() |> recalculate(unsigned["_target"])
    changeset = Catalog.change_product(socket.assigns.product, params)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, action: :validate))
     |> maybe_push_price(unsigned["_target"], params)}
  end

  def handle_event("save", %{"product" => params}, socket) do
    save_product(socket, socket.assigns.action, strip_money(params))
  end

  # The money inputs submit thousands-separated strings ("12.500"); strip the
  # separators so the changeset and price math see clean numbers.
  defp strip_money(params) do
    params
    |> strip_separators("purchase_price")
    |> strip_separators("price")
  end

  defp strip_separators(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> Map.put(params, key, String.replace(value, ".", ""))
      _ -> params
    end
  end

  # When purchase price or margin changed, the selling price was recomputed —
  # push the new value to the (hook-managed) selling-price input.
  defp maybe_push_price(socket, target, params)
       when target in [["product", "purchase_price"], ["product", "margin_percent"]] do
    push_event(socket, "money_set", %{id: "selling-price-input", value: money_str(params["price"])})
  end

  defp maybe_push_price(socket, _target, _params), do: socket

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
      # Store as a clean integer string (Rupiah) so the money input/formatting works.
      Map.put(params, "price", money_str(price))
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
