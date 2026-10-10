defmodule ZahlungsWeb.StoreLive.Register do
  @moduledoc """
  Branch registration wizard, admin only. Step 1 takes the store's data, step 2
  an optional first cashier. Nothing is saved until the end, and then the store
  and the cashier are saved together or not at all
  (`Zahlungs.Stores.register_branch/2`).
  """
  use ZahlungsWeb, :live_view

  import ZahlungsWeb.StoreLive.FormFields

  alias Zahlungs.{Accounts, Stores}
  alias Zahlungs.Accounts.User
  alias Zahlungs.Stores.Store

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Daftar Cabang", step: :store, store_params: %{}, cashier_params: %{})
     |> assign_store_form(%{})
     |> assign_cashier_form(%{})}
  end

  @impl true
  def handle_event("validate_store", %{"store" => params}, socket) do
    {:noreply, assign_store_form(socket, params, :validate)}
  end

  def handle_event("next", %{"store" => params}, socket) do
    case Ecto.Changeset.apply_action(Stores.change_store(%Store{}, params), :validate) do
      {:ok, _store} ->
        {:noreply,
         socket
         |> assign(step: :cashier, store_params: params)
         |> assign_store_form(params)
         |> assign_cashier_form(socket.assigns.cashier_params)}

      {:error, changeset} ->
        {:noreply, assign(socket, step: :store, store_form: to_form(changeset))}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, socket |> assign(:step, :store) |> assign_store_form(socket.assigns.store_params)}
  end

  def handle_event("validate_cashier", %{"user" => params}, socket) do
    {:noreply,
     socket |> assign(:cashier_params, params) |> assign_cashier_form(params, :validate)}
  end

  # Only step 2 can save: a `save`/`skip` that arrives earlier (a double
  # submit, a crafted event) would register a store nobody has validated.
  def handle_event("save", %{"user" => params}, %{assigns: %{step: :cashier}} = socket) do
    register(assign(socket, :cashier_params, params), params)
  end

  def handle_event("skip", _params, %{assigns: %{step: :cashier}} = socket) do
    register(socket, nil)
  end

  def handle_event(event, _params, socket) when event in ["save", "skip"] do
    {:noreply, socket}
  end

  defp register(socket, cashier_params) do
    case Stores.register_branch(socket.assigns.store_params, cashier_params) do
      {:ok, %{store: store}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Cabang #{store.name} terdaftar. Stoknya masih 0 — pilih cabang ini di menu atas, lalu isi stok lewat Products."
         )
         |> push_navigate(to: ~p"/admin/stores")}

      # E.g. the code was taken by someone else after step 1.
      {:error, :store, changeset} ->
        {:noreply, assign(socket, step: :store, store_form: to_form(changeset))}

      {:error, :cashier, changeset} ->
        {:noreply, assign(socket, :cashier_form, to_form(changeset, as: :user))}
    end
  end

  defp assign_store_form(socket, params, action \\ nil) do
    changeset = Stores.change_store(%Store{}, params)
    assign(socket, :store_form, to_form(changeset, action: action))
  end

  defp assign_cashier_form(socket, params, action \\ nil) do
    changeset = Accounts.change_user_registration(%User{}, params)
    assign(socket, :cashier_form, to_form(changeset, as: :user, action: action))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Daftar Cabang
      <:subtitle>Daftarkan toko cabang baru beserta akun kasir pertamanya (khusus admin).</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/stores"} class="btn btn-sm btn-link">Batal</.link>
      </:actions>
    </.header>

    <div :if={@step == :store} class="mt-6 max-w-xl">
      <h3 class="font-semibold text-gray-700">Langkah 1 dari 2 — Data toko</h3>

      <.form for={@store_form} id="branch-store-form" phx-change="validate_store" phx-submit="next">
        <.store_fields form={@store_form} />

        <div class="mt-6">
          <.button>Lanjut</.button>
        </div>
      </.form>
    </div>

    <div :if={@step == :cashier} class="mt-6 max-w-xl">
      <h3 class="font-semibold text-gray-700">Langkah 2 dari 2 — Kasir pertama (opsional)</h3>

      <dl class="mt-3 rounded-lg border border-gray-200 bg-gray-50 p-4 text-sm">
        <div class="flex justify-between">
          <dt class="text-gray-500">Toko</dt>
          <dd class="font-medium">{@store_params["name"]}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-gray-500">Kode</dt>
          <dd>{@store_params["code"] |> to_string() |> String.trim() |> String.upcase()}</dd>
        </div>
        <div :if={@store_params["address"] not in [nil, ""]} class="flex justify-between">
          <dt class="text-gray-500">Alamat</dt>
          <dd>{@store_params["address"]}</dd>
        </div>
      </dl>

      <p class="mt-4 text-sm text-gray-500">
        Akun kasir ini langsung terikat ke cabang baru. Lewati bila kasir akan ditambahkan nanti
        lewat menu Users.
      </p>

      <.form for={@cashier_form} id="branch-cashier-form" phx-change="validate_cashier" phx-submit="save">
        <.input field={@cashier_form[:name]} type="text" label="Nama kasir" />
        <.input field={@cashier_form[:email]} type="email" label="Email" required />
        <.input field={@cashier_form[:password]} type="password" label="Password" required />

        <div class="mt-6 flex flex-wrap items-center gap-3">
          <.button phx-disable-with="Menyimpan...">Daftarkan cabang</.button>
          <button type="button" phx-click="skip" class="btn btn-sm">Lewati</button>
          <button type="button" phx-click="back" class="btn btn-sm btn-link">Kembali</button>
        </div>
      </.form>
    </div>
    """
  end
end
