defmodule ZahlungsWeb.StoreLive.Index do
  @moduledoc """
  Store (branch) management, admin only: list, edit, and activate or deactivate.
  New stores are registered through `StoreLive.Register`. Stores are never
  deleted — sales and shifts keep pointing at them.
  """
  use ZahlungsWeb, :live_view

  import ZahlungsWeb.StoreLive.FormFields

  alias Zahlungs.Stores
  alias Zahlungs.Stores.Store

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_stores(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Toko", store: nil, form: nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    assign_form(socket, "Ubah toko", Stores.get_store!(id))
  end

  defp assign_form(socket, title, store) do
    assign(socket, page_title: title, store: store, form: to_form(Stores.change_store(store)))
  end

  @impl true
  def handle_event("validate", %{"store" => params}, socket) do
    changeset = Stores.change_store(socket.assigns.store, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"store" => params}, socket) do
    case Stores.update_store(socket.assigns.store, params) do
      {:ok, _store} ->
        {:noreply,
         socket
         |> put_flash(:info, "Toko disimpan.")
         |> load_stores()
         |> push_patch(to: ~p"/admin/stores")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    store = Stores.get_store!(id)
    current = socket.assigns.current_scope.store

    if (store.active and current) && current.id == store.id do
      {:noreply,
       put_flash(socket, :error, "Toko ini sedang Anda pakai. Pindah toko dulu di menu atas.")}
    else
      {:ok, updated} = Stores.set_store_active(store, !store.active)

      message =
        if updated.active,
          do: "Toko diaktifkan.",
          else: "Toko dinonaktifkan; kasirnya tidak bisa login sampai diaktifkan lagi."

      {:noreply, socket |> put_flash(:info, message) |> load_stores()}
    end
  end

  defp load_stores(socket), do: assign(socket, :stores, Stores.list_stores())

  defp coordinates(%Store{latitude: lat, longitude: lng}) when is_float(lat) and is_float(lng),
    do: "#{lat}, #{lng}"

  defp coordinates(%Store{}), do: "—"

  defp zone(7), do: "WIB (UTC+7)"
  defp zone(8), do: "WITA (UTC+8)"
  defp zone(9), do: "WIT (UTC+9)"
  defp zone(hours) when hours >= 0, do: "UTC+#{hours}"
  defp zone(hours), do: "UTC#{hours}"

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Toko
      <:subtitle>Kelola cabang (khusus admin). Stok, shift, dan penjualan terpisah per toko.</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/logins"} class="btn btn-sm btn-link">Riwayat login</.link>
        <.link navigate={~p"/admin/stores/register"}>
          <.button>Daftar cabang</.button>
        </.link>
      </:actions>
    </.header>

    <.table id="stores" rows={@stores}>
      <:col :let={store} label="Kode">{store.code}</:col>
      <:col :let={store} label="Nama">{store.name}</:col>
      <:col :let={store} label="Alamat">
        <div>{store.address || "—"}</div>
        <div :if={store.phone} class="text-xs text-gray-400">{store.phone}</div>
      </:col>
      <:col :let={store} label="Zona waktu">{zone(store.utc_offset_hours)}</:col>
      <:col :let={store} label="Koordinat">{coordinates(store)}</:col>
      <:col :let={store} label="Status">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (store.active && "bg-green-100 text-green-700") || "bg-red-100 text-red-700"
        ]}>
          {if store.active, do: "Aktif", else: "Nonaktif"}
        </span>
      </:col>
      <:action :let={store}>
        <.link patch={~p"/admin/stores/#{store}/edit"}>Ubah</.link>
      </:action>
      <:action :let={store}>
        <.link
          phx-click={JS.push("toggle_active", value: %{id: store.id})}
          data-confirm={store.active && "Nonaktifkan toko ini? Kasirnya tidak akan bisa login."}
        >
          {if store.active, do: "Nonaktifkan", else: "Aktifkan"}
        </.link>
      </:action>
    </.table>

    <.modal :if={@live_action == :edit} id="store-modal" show on_cancel={JS.patch(~p"/admin/stores")}>
      <.header>{@page_title}</.header>

      <.form for={@form} id="store-form" phx-change="validate" phx-submit="save">
        <.store_fields form={@form} deposit_account_options={Zahlungs.Deposits.account_options()} />

        <div class="mt-6">
          <.button phx-disable-with="Menyimpan...">Simpan</.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
