defmodule ZahlungsWeb.UserLiveTest do
  @moduledoc """
  Access-control + render tests for admin user management via `get/2` (no lazy_html).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

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

    test "renders the user list for admins", %{conn: conn} do
      admin = admin_fixture()
      conn = conn |> log_in_user(admin) |> get("/admin/users")
      response = html_response(conn, 200)
      assert response =~ "Users"
      assert response =~ admin.email
    end
  end
end
