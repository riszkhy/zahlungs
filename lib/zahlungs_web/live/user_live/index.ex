defmodule ZahlungsWeb.UserLive.Index do
  @moduledoc """
  Admin user management: list users, create users, and change roles.
  Admin-only via the router's admin live_session (`:ensure_admin`).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Accounts
  alias Zahlungs.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(reset_user: nil, reset_form: nil) |> load_users()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:page_title, "Users") |> assign(:user, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket |> assign(:page_title, "New User") |> assign(:user, %User{})
  end

  @impl true
  def handle_event("set_role", %{"id" => id, "role" => role}, socket) do
    id = to_int(id)

    if id == socket.assigns.current_user.id do
      {:noreply, put_flash(socket, :error, "You cannot change your own role.")}
    else
      {:ok, _} = Accounts.set_user_role(Accounts.get_user!(id), role)

      {:noreply,
       socket
       |> put_flash(:info, "Role updated.")
       |> load_users()}
    end
  end

  def handle_event("set_store", %{"user_id" => id, "store_id" => store_id}, socket) do
    user = Accounts.get_user!(to_int(id))
    store_id = if store_id in [nil, ""], do: nil, else: to_int(store_id)

    case Accounts.set_user_store(user, store_id) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "#{user.email} dipindahkan.") |> load_users()}

      {:error, changeset} ->
        {message, _opts} = Keyword.fetch!(changeset.errors, :store_id)
        {:noreply, socket |> put_flash(:error, message) |> load_users()}
    end
  end

  def handle_event("toggle_confirmed", %{"id" => id}, socket) do
    user = Accounts.get_user!(to_int(id))
    {:ok, updated} = Accounts.set_user_confirmed(user, is_nil(user.confirmed_at))

    msg =
      if updated.confirmed_at, do: "User ditandai confirmed.", else: "User ditandai unconfirmed."

    {:noreply, socket |> put_flash(:info, msg) |> load_users()}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    id = to_int(id)

    if id == socket.assigns.current_user.id do
      {:noreply, put_flash(socket, :error, "Anda tidak bisa menonaktifkan akun sendiri.")}
    else
      user = Accounts.get_user!(id)
      {:ok, updated} = Accounts.set_user_active(user, !user.active)

      msg =
        if updated.active,
          do: "User diaktifkan.",
          else: "User dinonaktifkan (sesi login-nya diakhiri)."

      {:noreply, socket |> put_flash(:info, msg) |> load_users()}
    end
  end

  def handle_event("prompt_reset", %{"id" => id}, socket) do
    id = to_int(id)

    if id == socket.assigns.current_user.id do
      {:noreply,
       put_flash(socket, :error, "Gunakan halaman Profile untuk mengubah password sendiri.")}
    else
      user = Accounts.get_user!(id)

      {:noreply,
       assign(socket,
         reset_user: user,
         reset_form: to_form(Accounts.change_user_password(user))
       )}
    end
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, reset_user: nil, reset_form: nil)}
  end

  def handle_event("validate_reset", %{"user" => params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.reset_user, params)
    {:noreply, assign(socket, :reset_form, to_form(changeset, action: :validate))}
  end

  def handle_event("do_reset", %{"user" => params}, socket) do
    case Accounts.reset_user_password(socket.assigns.reset_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(reset_user: nil, reset_form: nil)
         |> put_flash(:info, "Password #{user.email} berhasil direset (sesi lamanya diakhiri).")}

      {:error, changeset} ->
        {:noreply, assign(socket, :reset_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({ZahlungsWeb.UserLive.FormComponent, {:saved, _user}}, socket) do
    {:noreply, load_users(socket)}
  end

  # A single menu row inside the row "Actions" dropdown.
  attr :event, :string, required: true
  attr :value, :map, required: true
  attr :confirm, :string, default: nil
  attr :danger, :boolean, default: false
  slot :inner_block, required: true

  defp menu_link(assigns) do
    ~H"""
    <.link
      phx-click={JS.push(@event, value: @value)}
      data-confirm={@confirm}
      class={[
        "block px-3 py-1.5 text-sm hover:bg-gray-50",
        (@danger && "text-red-600") || "text-gray-700"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp load_users(socket) do
    assign(socket,
      users: Accounts.list_users(),
      store_options: Zahlungs.Stores.store_options()
    )
  end

  # A user still pointing at a deactivated store keeps it in their own list.
  defp store_options_for(%{store: %{id: id, name: name}}, options) do
    if Enum.any?(options, fn {_name, option_id} -> option_id == id end),
      do: options,
      else: [{"#{name} (nonaktif)", id} | options]
  end

  defp store_options_for(_user, options), do: options

  defp to_int(id) when is_integer(id), do: id
  defp to_int(id) when is_binary(id), do: String.to_integer(id)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Users
      <:subtitle>Kelola pengguna & role (khusus admin)</:subtitle>
      <:actions>
        <.link patch={~p"/admin/users/new"}>
          <.button>New User</.button>
        </.link>
      </:actions>
    </.header>

    <.table id="users" rows={@users}>
      <:col :let={user} label="Name">
        {if user.name in [nil, ""], do: "—", else: user.name}
      </:col>
      <:col :let={user} label="Email">
        {user.email}
        <span :if={user.id == @current_user.id} class="text-xs text-gray-400">(you)</span>
      </:col>
      <:col :let={user} label="Store">
        <form phx-change="set_store" id={"user-store-#{user.id}"}>
          <input type="hidden" name="user_id" value={user.id} />
          <select name="store_id" aria-label={"Toko untuk #{user.email}"} class="form-control text-sm py-1">
            <option :if={user.role == "admin" or is_nil(user.store_id)} value="">—</option>
            {Phoenix.HTML.Form.options_for_select(store_options_for(user, @store_options), user.store_id)}
          </select>
        </form>
      </:col>
      <:col :let={user} label="Role">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (user.role == "admin" && "bg-green-100 text-green-700") || "bg-gray-100 text-gray-700"
        ]}>
          {user.role}
        </span>
      </:col>
      <:col :let={user} label="Status">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (user.confirmed_at && "bg-green-100 text-green-700") || "bg-yellow-100 text-yellow-700"
        ]}>
          {if user.confirmed_at, do: "Confirmed", else: "Unconfirmed"}
        </span>
      </:col>
      <:col :let={user} label="Active">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (user.active && "bg-green-100 text-green-700") || "bg-red-100 text-red-700"
        ]}>
          {if user.active, do: "Active", else: "Inactive"}
        </span>
      </:col>
      <:col :let={user} label="Joined">{Calendar.strftime(Zahlungs.LocalTime.to_local(user.inserted_at), "%d %b %Y")}</:col>
      <:action :let={user}>
        <div class="relative" x-data="{ open: false }">
          <button
            type="button"
            @click="open = !open"
            class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
          >
            Actions ▾
          </button>
          <div
            x-show="open"
            @click.outside="open = false"
            x-transition
            style="display: none;"
            class="absolute right-0 z-20 mt-1 w-52 rounded-md border border-gray-200 bg-white py-1 text-left shadow-lg"
          >
            <.menu_link
              :if={user.id != @current_user.id and user.role != "admin"}
              event="set_role"
              value={%{id: user.id, role: "admin"}}
              confirm="Make this user an admin?"
            >
              Make admin
            </.menu_link>
            <.menu_link
              :if={user.id != @current_user.id and user.role == "admin"}
              event="set_role"
              value={%{id: user.id, role: "cashier"}}
              confirm="Demote this admin to cashier?"
            >
              Make cashier
            </.menu_link>
            <.menu_link
              event="toggle_confirmed"
              value={%{id: user.id}}
              confirm={
                if user.confirmed_at,
                  do: "Tandai user ini sebagai unconfirmed?",
                  else: "Tandai user ini sebagai confirmed?"
              }
            >
              {if user.confirmed_at, do: "Mark unconfirmed", else: "Mark confirmed"}
            </.menu_link>
            <.menu_link
              :if={user.id != @current_user.id}
              event="prompt_reset"
              value={%{id: user.id}}
            >
              Reset password
            </.menu_link>
            <div :if={user.id != @current_user.id} class="my-1 border-t border-gray-100"></div>
            <.menu_link
              :if={user.id != @current_user.id}
              event="toggle_active"
              value={%{id: user.id}}
              danger={user.active}
              confirm={
                if user.active,
                  do: "Nonaktifkan user ini? Sesi login aktifnya akan diakhiri.",
                  else: "Aktifkan kembali user ini?"
              }
            >
              {if user.active, do: "Deactivate", else: "Activate"}
            </.menu_link>
          </div>
        </div>
      </:action>
    </.table>

    <.modal :if={@live_action == :new} id="user-modal" show on_cancel={JS.patch(~p"/admin/users")}>
      <.live_component
        module={ZahlungsWeb.UserLive.FormComponent}
        id={:new}
        title={@page_title}
        action={:new}
        user={@user}
        patch={~p"/admin/users"}
      />
    </.modal>

    <.modal :if={@reset_user} id="reset-password-modal" show on_cancel={JS.push("cancel_reset")}>
      <.header>Reset password</.header>
      <p class="mt-1 text-sm text-gray-500">
        Setel password baru untuk <strong>{@reset_user.email}</strong>. Semua sesi login user itu akan diakhiri.
      </p>

      <.form for={@reset_form} id="reset-password-form" phx-change="validate_reset" phx-submit="do_reset">
        <.input field={@reset_form[:password]} type="password" label="New password" required />
        <.input field={@reset_form[:password_confirmation]} type="password" label="Confirm new password" required />

        <div class="mt-6 flex justify-end gap-2">
          <button type="button" phx-click="cancel_reset" class="btn btn-sm">Batal</button>
          <.button phx-disable-with="Saving...">Reset password</.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
