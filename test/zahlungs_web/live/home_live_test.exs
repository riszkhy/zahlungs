defmodule ZahlungsWeb.HomeLiveTest do
  @moduledoc """
  Tests the home dashboard via the disconnected render (`get/2`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  describe "/home" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/home")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "greets the user and shows summary cards", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get("/home")
      response = html_response(conn, 200)
      assert response =~ "Home"
      assert response =~ user.email
      assert response =~ "Active Products"
      assert response =~ "Low Stock"
    end

    test "shows admin quick actions only for admins", %{conn: conn} do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
      cashier = user_fixture()

      admin_resp = conn |> log_in_user(admin) |> get("/home") |> html_response(200)
      assert admin_resp =~ "Manage Products"

      cashier_resp = build_conn() |> log_in_user(cashier) |> get("/home") |> html_response(200)
      refute cashier_resp =~ "Manage Products"
    end
  end
end
