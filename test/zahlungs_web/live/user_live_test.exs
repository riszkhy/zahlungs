defmodule ZahlungsWeb.UserLiveTest do
  @moduledoc """
  Admin user management tests: access control and render via `get/2`, and the
  row actions by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Accounts
  alias ZahlungsWeb.UserLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/admin/users access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/users")) == "/users/log_in"
    end

    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/admin/users")
      assert redirected_to(conn) == "/"
    end

    test "renders the user list with a reset-password action for admins", %{conn: conn} do
      admin = admin_fixture()
      other = user_fixture()

      conn = conn |> log_in_user(admin) |> get("/admin/users")
      response = html_response(conn, 200)
      assert response =~ "Users"
      assert response =~ admin.email
      assert response =~ other.email
      assert response =~ "Reset password"
      assert response =~ "Deactivate"
    end
  end

  describe "row actions" do
    setup do
      admin = admin_fixture()
      %{admin: admin, other: user_fixture(), socket: mount_live(UserLive.Index, admin)}
    end

    test "set_role changes another user's role", %{socket: socket, other: other} do
      socket = event(socket, "set_role", %{"id" => other.id, "role" => "admin"})

      assert flash(socket, :info) == "Role updated."
      assert Accounts.get_user!(other.id).role == "admin"
    end

    test "an admin cannot change their own role", %{socket: socket, admin: admin} do
      socket = event(socket, "set_role", %{"id" => "#{admin.id}", "role" => "cashier"})

      assert flash(socket, :error) == "You cannot change your own role."
      assert Accounts.get_user!(admin.id).role == "admin"
    end

    test "toggle_active locks a user out and lets them back in", %{socket: socket, other: other} do
      password = valid_user_password()
      token = Accounts.generate_user_session_token(other)

      socket = event(socket, "toggle_active", %{"id" => other.id})

      assert flash(socket, :info) =~ "dinonaktifkan"
      refute Accounts.get_user_by_email_and_password(other.email, password)
      refute Accounts.get_user_by_session_token(token)

      socket = event(socket, "toggle_active", %{"id" => other.id})

      assert flash(socket, :info) == "User diaktifkan."
      assert Accounts.get_user_by_email_and_password(other.email, password)
    end

    test "an admin cannot deactivate themselves", %{socket: socket, admin: admin} do
      socket = event(socket, "toggle_active", %{"id" => admin.id})

      assert flash(socket, :error) =~ "akun sendiri"
      assert Accounts.get_user!(admin.id).active
    end

    test "toggle_confirmed marks a user confirmed and back", %{socket: socket, other: other} do
      assert is_nil(other.confirmed_at)

      socket = event(socket, "toggle_confirmed", %{"id" => other.id})
      assert flash(socket, :info) == "User ditandai confirmed."
      assert Accounts.get_user!(other.id).confirmed_at

      socket = event(socket, "toggle_confirmed", %{"id" => other.id})
      assert flash(socket, :info) == "User ditandai unconfirmed."
      assert is_nil(Accounts.get_user!(other.id).confirmed_at)
    end
  end

  describe "password reset" do
    setup do
      admin = admin_fixture()
      %{admin: admin, other: user_fixture(), socket: mount_live(UserLive.Index, admin)}
    end

    test "sets a new password and ends the user's sessions", %{socket: socket, other: other} do
      token = Accounts.generate_user_session_token(other)
      socket = event(socket, "prompt_reset", %{"id" => other.id})
      assert socket.assigns.reset_user.id == other.id

      socket =
        event(socket, "do_reset", %{
          "user" => %{
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert flash(socket, :info) =~ other.email
      assert is_nil(socket.assigns.reset_user)
      assert Accounts.get_user_by_email_and_password(other.email, "a brand new password")
      refute Accounts.get_user_by_email_and_password(other.email, valid_user_password())
      refute Accounts.get_user_by_session_token(token)
    end

    test "keeps the form open with errors when the password is invalid",
         %{socket: socket, other: other} do
      socket =
        socket
        |> event("prompt_reset", %{"id" => other.id})
        |> event("do_reset", %{
          "user" => %{"password" => "short", "password_confirmation" => "different"}
        })

      assert socket.assigns.reset_user.id == other.id
      assert socket.assigns.reset_form.errors[:password]
      assert Accounts.get_user_by_email_and_password(other.email, valid_user_password())
    end

    test "is not offered for the admin's own account", %{socket: socket, admin: admin} do
      socket = event(socket, "prompt_reset", %{"id" => admin.id})

      assert flash(socket, :error) =~ "Profile"
      assert is_nil(socket.assigns.reset_user)
    end

    test "can be cancelled", %{socket: socket, other: other} do
      socket = socket |> event("prompt_reset", %{"id" => other.id}) |> event("cancel_reset")

      assert is_nil(socket.assigns.reset_user)
      assert is_nil(socket.assigns.reset_form)
    end
  end
end
