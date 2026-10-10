defmodule ZahlungsWeb.LoginLive.Index do
  @moduledoc """
  Login history, admin only: who logged in, when, from which store's account,
  and where the browser said the device was. An audit trail — the position can
  be missing, imprecise or faked, and is never used to refuse a login.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Accounts, Stores}

  @limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Riwayat login", store_id: "", user_id: "", limit: @limit)
     |> assign(:store_options, Stores.list_stores() |> Enum.map(&{&1.name, &1.id}))
     |> assign(:user_options, Accounts.list_users() |> Enum.map(&{&1.email, &1.id}))
     |> load_logins()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(store_id: params["store_id"] || "", user_id: params["user_id"] || "")
     |> load_logins()}
  end

  defp load_logins(socket) do
    logins =
      Accounts.list_user_logins(
        store_id: to_id(socket.assigns.store_id),
        user_id: to_id(socket.assigns.user_id),
        limit: @limit
      )

    assign(socket, :logins, logins)
  end

  defp to_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  defp distance(nil), do: "—"
  defp distance(metres) when metres < 1000, do: "#{round(metres)} m"

  defp distance(metres) do
    km = Float.round(metres / 1000, 1)
    String.replace("#{km} km", ".", ",")
  end

  defp map_url(login), do: "https://www.google.com/maps?q=#{login.latitude},#{login.longitude}"

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Riwayat login
      <:subtitle>
        Lokasi berasal dari browser: bisa kosong, meleset, atau dipalsukan. Jejak audit, bukan bukti.
      </:subtitle>
      <:actions>
        <.link navigate={~p"/admin/stores"} class="btn btn-sm btn-link">Toko</.link>
      </:actions>
    </.header>

    <form phx-change="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm">
        Toko
        <select name="store_id" class="form-control">
          <option value="">Semua</option>
          {Phoenix.HTML.Form.options_for_select(@store_options, @store_id)}
        </select>
      </label>
      <label class="text-sm">
        User
        <select name="user_id" class="form-control">
          <option value="">Semua</option>
          {Phoenix.HTML.Form.options_for_select(@user_options, @user_id)}
        </select>
      </label>
    </form>

    <.table id="logins" rows={@logins}>
      <:col :let={login} label="Waktu">
        {Calendar.strftime(Zahlungs.LocalTime.to_local(login.inserted_at, login.store), "%d %b %Y %H:%M")}
      </:col>
      <:col :let={login} label="User">{login.user && login.user.email}</:col>
      <:col :let={login} label="Toko">{(login.store && login.store.name) || "—"}</:col>
      <:col :let={login} label="Lokasi">
        <a :if={login.latitude} href={map_url(login)} target="_blank" rel="noopener" class="underline">
          {Float.round(login.latitude, 5)}, {Float.round(login.longitude, 5)}
        </a>
        <span :if={login.latitude && login.accuracy_m} class="text-xs text-gray-400">
          ±{round(login.accuracy_m)} m
        </span>
        <span :if={is_nil(login.latitude)} class="text-gray-400">tanpa lokasi</span>
      </:col>
      <:col :let={login} label="Jarak dari toko">{distance(login.distance_m)}</:col>
      <:col :let={login} label="IP">{login.ip || "—"}</:col>
    </.table>
    <p :if={@logins == []} class="mt-2 text-sm text-gray-500">Belum ada login yang tercatat.</p>
    <p :if={length(@logins) == @limit} class="mt-2 text-sm text-gray-500">
      Menampilkan {@limit} login terbaru; persempit dengan filter.
    </p>
    """
  end
end
