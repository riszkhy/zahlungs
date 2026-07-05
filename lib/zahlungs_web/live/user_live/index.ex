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

    cond do
      id == socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "You cannot change your own role.")}

      true ->
        {:ok, _} = Accounts.set_user_role(Accounts.get_user!(id), role)

        {:noreply,
         socket
         |> put_flash(:info, "Role updated.")
         |> load_users()}
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

  defp load_users(socket), do: assign(socket, :users, Accounts.list_users())

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
      <:col :let={user} label="Role">
        <span class={[
          "text-xs px-2 py-0.5 rounded-full",
          (user.role == "admin" && "bg-green-100 text-green-700") || "bg-gray-100 text-gray-700"
        ]}>
          {user.role}
        </span>
      </:col>
      <:col :let={user} label="Status">
        {if user.confirmed_at, do: "Confirmed", else: "Unconfirmed"}
      </:col>
      <:col :let={user} label="Joined">{Calendar.strftime(user.inserted_at, "%d %b %Y")}</:col>
      <:action :let={user}>
        <.link
          :if={user.id != @current_user.id and user.role != "admin"}
          phx-click={JS.push("set_role", value: %{id: user.id, role: "admin"})}
          data-confirm="Make this user an admin?"
        >
          Make admin
        </.link>
        <.link
          :if={user.id != @current_user.id and user.role == "admin"}
          phx-click={JS.push("set_role", value: %{id: user.id, role: "cashier"})}
          data-confirm="Demote this admin to cashier?"
        >
          Make cashier
        </.link>
        <.link
          :if={user.id != @current_user.id}
          phx-click={JS.push("prompt_reset", value: %{id: user.id})}
        >
          Reset password
        </.link>
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
