defmodule ZahlungsWeb.PromotionLive.Index do
  @moduledoc """
  Promotions, admin only: percent or rupiah off products or categories for a
  date range, in all stores or chosen ones; and the limit on a cashier's
  manual discount. The form is inline (no live component), and products are
  picked by searching.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Catalog, Promotions, Stores}
  alias Zahlungs.Promotions.Promotion

  @impl true
  def mount(_params, _session, socket) do
    org_id = socket.assigns.current_user.organization_id

    {:ok,
     socket
     |> assign(
       category_options: Catalog.category_options(),
       store_options: Stores.store_options(),
       limit: format_limit(Promotions.cashier_discount_limit(org_id)),
       product_query: "",
       product_results: [],
       picked: []
     )
     |> load_promotions()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Promo", promotion: nil, form: nil, picked: [])
  end

  defp apply_action(socket, :new, _params) do
    today = Zahlungs.LocalTime.today(socket.assigns.current_scope.store)
    promotion = %Promotion{starts_on: today, ends_on: Date.add(today, 6)}

    socket
    |> assign(page_title: "Promo baru", picked: [])
    |> put_form(promotion)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    promotion = Promotions.get_promotion!(id)

    picked = for %{product: %{id: id, name: name}} <- promotion.targets, do: %{id: id, name: name}

    socket
    |> assign(page_title: "Ubah promo", picked: picked)
    |> put_form(promotion)
  end

  defp put_form(socket, promotion, changeset \\ nil) do
    assign(socket,
      promotion: promotion,
      form: to_form(changeset || Promotions.change_promotion(promotion))
    )
  end

  @impl true
  def handle_event("product_search", %{"q" => q}, socket) do
    results =
      if String.trim(q) == "",
        do: [],
        else: Catalog.list_products(socket.assigns.current_scope, search: q, limit: 8)

    {:noreply, assign(socket, product_query: q, product_results: results)}
  end

  def handle_event("add_product", %{"id" => id}, socket) do
    id = to_int(id)

    picked =
      case Enum.find(socket.assigns.product_results, &(&1.id == id)) do
        nil -> socket.assigns.picked
        product -> Enum.uniq_by(socket.assigns.picked ++ [%{id: id, name: product.name}], & &1.id)
      end

    {:noreply, assign(socket, picked: picked, product_query: "", product_results: [])}
  end

  def handle_event("remove_product", %{"id" => id}, socket) do
    id = to_int(id)
    {:noreply, assign(socket, :picked, Enum.reject(socket.assigns.picked, &(&1.id == id)))}
  end

  def handle_event("save", %{"promotion" => params}, socket) do
    user = socket.assigns.current_user

    params =
      params
      |> Map.put("product_ids", Enum.map(socket.assigns.picked, & &1.id))
      |> Map.put_new("category_ids", [])
      |> Map.put_new("store_ids", [])

    result =
      case socket.assigns.promotion do
        %Promotion{id: nil} -> Promotions.create_promotion(user, params)
        promotion -> Promotions.update_promotion(user, promotion, params)
      end

    case result do
      {:ok, _promotion} ->
        {:noreply,
         socket
         |> put_flash(:info, "Promo disimpan.")
         |> load_promotions()
         |> push_patch(to: ~p"/admin/promotions")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_form(socket, socket.assigns.promotion, Map.put(changeset, :action, :insert))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Hanya admin yang bisa mengatur promo.")}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    promotion = Promotions.get_promotion!(to_int(id))

    case Promotions.set_active(socket.assigns.current_user, promotion, not promotion.active) do
      {:ok, _} -> {:noreply, load_promotions(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Promo tidak bisa diubah.")}
    end
  end

  def handle_event("save_limit", %{"limit" => limit}, socket) do
    case Promotions.set_cashier_discount_limit(socket.assigns.current_user, limit) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:limit, format_limit(organization.max_cashier_discount_percent))
         |> put_flash(:info, "Batas diskon kasir disimpan.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Batas harus antara 0 dan 100, atau kosong.")}
    end
  end

  defp load_promotions(socket), do: assign(socket, :rows, Promotions.list_promotions())

  defp to_int(id) when is_integer(id), do: id
  defp to_int(id) when is_binary(id), do: String.to_integer(id)

  defp format_limit(nil), do: ""
  defp format_limit(limit), do: limit |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp status_label(:running), do: "Berjalan"
  defp status_label(:scheduled), do: "Terjadwal"
  defp status_label(:ended), do: "Selesai"
  defp status_label(:inactive), do: "Nonaktif"

  defp status_class(:running), do: "bg-green-100 text-green-800"
  defp status_class(:scheduled), do: "bg-blue-100 text-blue-800"
  defp status_class(_), do: "bg-gray-100 text-gray-600"

  defp off_label(%Promotion{kind: "percent", value: value}),
    do: "−#{value |> Decimal.normalize() |> Decimal.to_string(:normal)}%"

  defp off_label(%Promotion{value: value}), do: "−#{format_money(value)} / barang"

  defp targets_label(%Promotion{targets: targets}) do
    targets
    |> Enum.map(fn
      %{product: %{name: name}} -> name
      %{category: %{name: name}} -> "Kategori #{name}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp stores_label(%Promotion{all_stores: true}), do: "Semua cabang"
  defp stores_label(%Promotion{stores: stores}), do: Enum.map_join(stores, ", ", & &1.store.name)

  defp date(date), do: Calendar.strftime(date, "%d/%m/%Y")

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Promo
      <:subtitle>Potongan otomatis untuk produk atau kategori (khusus admin)</:subtitle>
      <:actions>
        <.link patch={~p"/admin/promotions/new"}>
          <.button>Promo baru</.button>
        </.link>
      </:actions>
    </.header>

    <form id="discount-limit" phx-submit="save_limit" class="mt-4 flex flex-wrap items-end gap-2 text-sm">
      <label>
        Batas diskon manual kasir (% dari subtotal; kosong = tanpa batas)
        <input type="number" name="limit" min="0" max="100" step="0.01" value={@limit} class="form-control w-32" />
      </label>
      <button type="submit" class="chip">Simpan batas</button>
    </form>

    <.table id="promotions" rows={@rows}>
      <:col :let={row} label="Promo">
        <span class="font-medium">{row.promotion.name}</span>
        <div class="text-xs text-gray-500">{targets_label(row.promotion)}</div>
      </:col>
      <:col :let={row} label="Potongan">{off_label(row.promotion)}</:col>
      <:col :let={row} label="Tanggal">
        {date(row.promotion.starts_on)} – {date(row.promotion.ends_on)}
      </:col>
      <:col :let={row} label="Cabang">{stores_label(row.promotion)}</:col>
      <:col :let={row} label="Status">
        <span class={["rounded px-2 py-0.5 text-xs", status_class(row.status)]}>
          {status_label(row.status)}
        </span>
      </:col>
      <:action :let={row}>
        <.link patch={~p"/admin/promotions/#{row.promotion.id}/edit"}>Ubah</.link>
      </:action>
      <:action :let={row}>
        <.link phx-click={JS.push("toggle_active", value: %{id: row.promotion.id})}>
          {if row.promotion.active, do: "Nonaktifkan", else: "Aktifkan"}
        </.link>
      </:action>
    </.table>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="promotion-modal"
      show
      on_cancel={JS.patch(~p"/admin/promotions")}
    >
      <.header>{@page_title}</.header>

      <div class="mt-4 text-sm">
        <p class="font-medium">Produk</p>
        <div :if={@picked != []} class="mt-1 flex flex-wrap gap-1">
          <span :for={p <- @picked} class="chip-sm chip-sm-active">
            {p.name}
            <button type="button" phx-click={JS.push("remove_product", value: %{id: p.id})} aria-label="Hapus">×</button>
          </span>
        </div>
        <form phx-change="product_search" phx-submit="product_search" class="mt-1">
          <input type="search" name="q" value={@product_query} placeholder="Cari produk (nama / SKU)" phx-debounce="250" autocomplete="off" class="form-control" />
        </form>
        <div :if={@product_results != []} class="mt-1 divide-y divide-gray-100 rounded border border-gray-200">
          <button
            :for={p <- @product_results}
            type="button"
            phx-click={JS.push("add_product", value: %{id: p.id})}
            class="block w-full px-2 py-1.5 text-left hover:bg-gray-50"
          >
            {p.name}
            <span :if={p.consignment} class="text-xs text-gray-500">(titipan, tidak kena promo)</span>
          </button>
        </div>
      </div>

      <.form for={@form} id="promotion-form" phx-submit="save" class="mt-4">
        <.input field={@form[:name]} type="text" label="Nama promo" required />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:kind]} type="select" label="Jenis" options={[{"Persen (%)", "percent"}, {"Rupiah per barang", "amount"}]} />
          <.input field={@form[:value]} type="number" label="Nilai" min="0" step="any" />
          <.input field={@form[:starts_on]} type="date" label="Mulai" />
          <.input field={@form[:ends_on]} type="date" label="Selesai" />
        </div>

        <fieldset class="mt-3 text-sm">
          <legend class="font-medium">Kategori</legend>
          <label :for={{name, id} <- @category_options} class="mr-3 inline-flex items-center gap-1">
            <input
              type="checkbox"
              name="promotion[category_ids][]"
              value={id}
              checked={id in (@form[:category_ids].value || [])}
            />
            {name}
          </label>
        </fieldset>
        <p :for={msg <- Enum.map(@form[:product_ids].errors, &translate_error/1)} class="mt-1 text-sm text-red-600">
          {msg}
        </p>

        <.input field={@form[:all_stores]} type="checkbox" label="Semua cabang" />
        <fieldset class="text-sm">
          <legend class="font-medium">Atau cabang tertentu</legend>
          <label :for={{name, id} <- @store_options} class="mr-3 inline-flex items-center gap-1">
            <input
              type="checkbox"
              name="promotion[store_ids][]"
              value={id}
              checked={id in (@form[:store_ids].value || [])}
            />
            {name}
          </label>
        </fieldset>
        <p :for={msg <- Enum.map(@form[:store_ids].errors, &translate_error/1)} class="mt-1 text-sm text-red-600">
          {msg}
        </p>

        <.input field={@form[:active]} type="checkbox" label="Aktif" />

        <div class="mt-6">
          <.button phx-disable-with="Menyimpan...">Simpan</.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
