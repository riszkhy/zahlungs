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
    {:ok,
     socket
     |> assign(page_title: "Produk layanan", category: "")
     |> assign(catalog_account: Services.catalog_account(), catalog: [], price_rows: nil)
     |> load_products()}
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

  # The vendor's price list, searched while the form is open.
  def handle_event("search_catalog", %{"q" => query}, socket) do
    case Services.search_catalog(socket.assigns.catalog_account, query) do
      {:ok, items} ->
        {:noreply, assign(socket, :catalog, items)}

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign(:catalog, [])
         |> put_flash(:error, "Daftar harga SBI tidak bisa diambil.")}
    end
  end

  # Fills the form from a catalog item; the admin can still change anything.
  def handle_event("pick_catalog", %{"code" => code}, socket) do
    case Enum.find(socket.assigns.catalog, &(&1.code == code)) do
      nil ->
        {:noreply, socket}

      item ->
        params =
          socket.assigns.form.params
          |> Map.merge(%{"name" => item.name, "provider_code" => item.code})
          |> put_if("category", item.category_hint)
          |> put_if(
            "cost",
            item.category_hint != "tagihan_pln" && item.price && Decimal.to_string(item.price)
          )

        {:noreply, socket |> assign(:catalog, []) |> change(params, :validate)}
    end
  end

  def handle_event("price_update", _params, socket) do
    case Services.price_update(socket.assigns.catalog_account) do
      {:ok, rows} ->
        {:noreply, assign(socket, :price_rows, rows)}

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Harga SBI tidak bisa diambil. Coba lagi.")}
    end
  end

  def handle_event("apply_price_update", _params, socket) do
    {:ok, count} =
      Services.apply_price_update(socket.assigns.catalog_account, socket.assigns.price_rows || [])

    {:noreply,
     socket
     |> assign(:price_rows, nil)
     |> put_flash(:info, "#{count} produk diperbarui.")
     |> load_products()}
  end

  def handle_event("cancel_price_update", _params, socket),
    do: {:noreply, assign(socket, :price_rows, nil)}

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

  defp put_if(params, _key, value) when value in [nil, false], do: params
  defp put_if(params, key, value), do: Map.put(params, key, value)

  defp vendor_status("gangguan"), do: "Gangguan"
  defp vendor_status("kosong"), do: "Kosong"
  defp vendor_status("tidak_ditemukan"), do: "Tidak ditemukan"
  defp vendor_status(_normal), do: nil

  defp vendor_price_up?(%Product{provider_price: %Decimal{} = price, cost: cost}),
    do: Decimal.gt?(price, cost)

  defp vendor_price_up?(_product), do: false

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
        <button :if={@catalog_account} type="button" phx-click="price_update" phx-disable-with="Mengambil harga..." class="chip mr-2">
          Perbarui dari SBI
        </button>
        <.link patch={~p"/admin/services/new"}><.button>Produk baru</.button></.link>
      </:actions>
    </.header>

    <section :if={@price_rows} id="price-update" class="mt-6 rounded-lg border border-gray-200 p-4">
      <h3 class="font-semibold">Perubahan dari SBI ({length(@price_rows)} produk)</h3>
      <p :if={@price_rows == []} class="mt-2 text-sm text-gray-500">SBI tidak menjawab untuk produk mana pun.</p>
      <div :for={row <- @price_rows} class="mt-2 flex flex-wrap justify-between gap-2 text-sm">
        <span class="font-medium">{row.product.name} <span class="text-gray-500">({row.product.provider_code})</span></span>
        <span>
          Modal {format_money(row.old_cost)} → {format_money(row.new_cost)}
          <span :if={row.new_price}>· harga {format_money(row.new_price)}</span>
          <span :if={vendor_status(row.status)} class="ml-1 rounded-full bg-amber-100 px-2 text-xs text-amber-800">
            {vendor_status(row.status)}
          </span>
        </span>
      </div>
      <div class="mt-4 flex gap-2">
        <.button phx-click="apply_price_update">Simpan perubahan</.button>
        <button type="button" phx-click="cancel_price_update" class="chip">Batal</button>
      </div>
    </section>

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
        <span :if={vendor_status(product.provider_status)} class="ml-1 rounded-full bg-amber-100 px-2 text-xs text-amber-800">
          {vendor_status(product.provider_status)}
        </span>
        <span :if={vendor_price_up?(product)} class="ml-1 rounded-full bg-red-100 px-2 text-xs text-red-700">
          Modal SBI naik
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

      <form :if={@catalog_account} phx-change="search_catalog" phx-submit="search_catalog" class="mt-4">
        <label class="block text-sm">
          Cari di daftar SBI
          <input type="search" name="q" phx-debounce="400" placeholder="mis. telkomsel 10, pln 20" class="form-control" autocomplete="off" />
        </label>
      </form>
      <div :if={@catalog != []} id="catalog-results" class="mt-2 max-h-60 overflow-y-auto rounded border border-gray-200">
        <button
          :for={item <- @catalog}
          type="button"
          phx-click={JS.push("pick_catalog", value: %{code: item.code})}
          class="flex w-full justify-between gap-2 border-b border-gray-100 px-3 py-2 text-left text-sm hover:bg-gray-50"
        >
          <span><span class="font-medium">{item.code}</span> · {item.name}</span>
          <span class="text-right text-gray-600">
            <span :if={item.price}>{format_money(item.price)}</span>
            <span :if={item.admin}>Admin {format_money(item.admin)} · Komisi {format_money(item.commission || Decimal.new(0))}</span>
            <span :if={vendor_status(item.status)} class="ml-1 text-amber-700">{vendor_status(item.status)}</span>
          </span>
        </button>
      </div>

      <.form for={@form} id="service-product-form" phx-change="validate" phx-submit="save" class="mt-4 space-y-1">
        <.input field={@form[:name]} type="text" label="Nama (mis. Pulsa Telkomsel 10.000)" required />
        <.input field={@form[:category]} type="select" label="Kategori" options={Enum.map(Services.categories(), fn {v, l} -> {l, v} end)} />
        <.input field={@form[:operator]} type="text" label="Operator (opsional)" />
        <.input field={@form[:provider_code]} type="text" label="Kode produk vendor (untuk akun API)" maxlength="60" />
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
        <.input
          :if={bill_form?(@form)}
          field={@form[:api_extra_fee]}
          type="number"
          step="1"
          min="0"
          label="Biaya tambahan toko (akun API), per lembar di atas total penyedia"
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
