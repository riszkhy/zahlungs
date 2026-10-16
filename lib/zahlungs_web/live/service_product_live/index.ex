defmodule ZahlungsWeb.ServiceProductLive.Index do
  @moduledoc """
  Admin page for PPOB service products: the list with each product's price,
  and the create/edit form with a live price preview. The form lives in this
  view (not a live component) so its preview can be driven in tests.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Services
  alias Zahlungs.Services.Product

  # The bill the preview of a tagihan PLN product is shown for.
  @sample_bill Decimal.new(100_000)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Produk layanan", category: "") |> load_products()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params),
    do: assign(socket, product: nil, form: nil, preview: nil)

  defp apply_action(socket, :new, _params) do
    socket |> assign(:product, %Product{category: "pulsa"}) |> change(%{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket |> assign(:product, Services.get_product!(id)) |> change(%{})
  end

  @impl true
  def handle_event("filter", %{"category" => category}, socket) do
    {:noreply, socket |> assign(:category, category) |> load_products()}
  end

  def handle_event("validate", %{"product" => params}, socket) do
    {:noreply, change(socket, params, :validate)}
  end

  def handle_event("save", %{"product" => params}, socket) do
    result =
      case socket.assigns.product do
        %Product{id: nil} -> Services.create_product(params)
        product -> Services.update_product(product, params)
      end

    case result do
      {:ok, product} ->
        {:noreply,
         socket
         |> put_flash(:info, "Produk layanan #{product.name} disimpan.")
         |> load_products()
         |> push_patch(to: ~p"/admin/services")}

      {:error, changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_preview(changeset)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, product} = id |> Services.get_product!() |> Services.delete_product()

    {:noreply,
     socket |> put_flash(:info, "Produk layanan #{product.name} dihapus.") |> load_products()}
  end

  defp change(socket, params, action \\ nil) do
    changeset = Services.change_product(socket.assigns.product, params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket |> assign(:form, to_form(changeset)) |> assign_preview(changeset)
  end

  # The price as the form stands, when the numbers make one.
  defp assign_preview(socket, changeset) do
    product = Ecto.Changeset.apply_changes(changeset)

    preview =
      with true <- valid_numbers?(product),
           {:ok, %{price: price, cost: cost}} <-
             Services.price_for(product, if(Product.bill?(product), do: @sample_bill)) do
        %{bill?: Product.bill?(product), price: price, cost: cost}
      else
        _ -> nil
      end

    assign(socket, :preview, preview)
  end

  defp valid_numbers?(%Product{cost: %Decimal{}, margin_value: %Decimal{}}), do: true
  defp valid_numbers?(_product), do: false

  defp load_products(socket) do
    assign(socket, :products, Services.list_products(category: socket.assigns.category))
  end

  defp bill_form?(form), do: Ecto.Changeset.get_field(form.source, :category) == "tagihan_pln"

  defp category_label(category) do
    Enum.find_value(Services.categories(), category, fn {value, label} ->
      if value == category, do: label
    end)
  end

  defp margin_label(%Product{margin_type: "percent", margin_value: value}), do: "#{value}%"
  defp margin_label(%Product{margin_value: value}), do: format_money(value)

  defp price_label(product) do
    case Services.price_for(product, nil) do
      {:ok, %{price: price}} -> format_money(price)
      {:error, :bill_required} -> "Tagihan + #{margin_label(product)}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Produk layanan
      <:subtitle>Pulsa, paket data, token dan tagihan PLN (khusus admin)</:subtitle>
      <:actions>
        <.link patch={~p"/admin/services/new"}><.button>Produk baru</.button></.link>
      </:actions>
    </.header>

    <form phx-change="filter" class="mt-6">
      <select name="category" class="form-control max-w-xs" aria-label="Kategori">
        <option value="" selected={@category == ""}>Semua kategori</option>
        <option :for={{value, label} <- Services.categories()} value={value} selected={@category == value}>
          {label}
        </option>
      </select>
    </form>

    <.table id="service-products" rows={@products}>
      <:col :let={product} label="Nama">{product.name}</:col>
      <:col :let={product} label="Kategori">{category_label(product.category)}</:col>
      <:col :let={product} label="Modal">{format_money(product.cost)}</:col>
      <:col :let={product} label="Margin">{margin_label(product)}</:col>
      <:col :let={product} label="Harga">{price_label(product)}</:col>
      <:col :let={product} label="Status">
        <span class={if product.active, do: "text-green-600", else: "text-gray-400"}>
          {if product.active, do: "Aktif", else: "Nonaktif"}
        </span>
      </:col>
      <:action :let={product}>
        <.link patch={~p"/admin/services/#{product}/edit"}>Edit</.link>
      </:action>
      <:action :let={product}>
        <.link
          phx-click={JS.push("delete", value: %{id: product.id})}
          data-confirm="Hapus produk layanan ini? Transaksi lamanya tetap tersimpan."
        >
          Hapus
        </.link>
      </:action>
    </.table>

    <.modal :if={@form} id="service-product-modal" show on_cancel={JS.patch(~p"/admin/services")}>
      <h3 class="text-lg font-semibold">{if @product.id, do: "Ubah produk layanan", else: "Produk layanan baru"}</h3>

      <.form for={@form} id="service-product-form" phx-change="validate" phx-submit="save" class="mt-4 space-y-1">
        <.input field={@form[:name]} type="text" label="Nama (mis. Pulsa Telkomsel 10.000)" required />
        <.input field={@form[:category]} type="select" label="Kategori" options={Enum.map(Services.categories(), fn {v, l} -> {l, v} end)} />
        <.input field={@form[:operator]} type="text" label="Operator (opsional)" />
        <.input
          field={@form[:cost]}
          type="number"
          step="1"
          min="0"
          label={if bill_form?(@form), do: "Biaya penyedia (Rp, di atas tagihan)", else: "Modal (Rp, yang dipotong penyedia)"}
        />
        <.input field={@form[:margin_type]} type="select" label="Jenis margin" options={[{"Rupiah", "amount"}, {"Persen", "percent"}]} />
        <.input
          field={@form[:margin_value]}
          type="number"
          step="0.01"
          min="0"
          label={if bill_form?(@form), do: "Biaya admin ke pelanggan", else: "Margin"}
        />
        <.input field={@form[:active]} type="checkbox" label="Aktif (bisa dijual)" />

        <p :if={@preview && not @preview.bill?} class="mt-3 rounded bg-gray-50 p-3 text-sm">
          Harga jual: <strong>{format_money(@preview.price)}</strong>
        </p>
        <p :if={@preview && @preview.bill?} class="mt-3 rounded bg-gray-50 p-3 text-sm">
          Contoh tagihan Rp 100.000: harga <strong>{format_money(@preview.price)}</strong>,
          modal {format_money(@preview.cost)}
        </p>

        <div class="mt-6"><.button class="w-full">Simpan</.button></div>
      </.form>
    </.modal>
    """
  end
end
