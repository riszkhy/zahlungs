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
    {:ok, load_users(socket)}
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
    """
  end
end
