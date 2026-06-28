defmodule ZahlungsWeb.ProductLiveTest do
  @moduledoc """
  Access-control tests for the admin product management LiveView.

  These use plain `get/2` (the disconnected render) rather than `live/2`, so they
  exercise the router-level role gating without requiring the `lazy_html`
  dependency that the connected LiveView test helpers need.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/products access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/products")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/products")
      assert redirected_to(conn) == "/"
    end

    test "renders for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/products")
      assert html_response(conn, 200) =~ "Product Management"
    end
  end

  describe "/categories access control" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/categories")
      assert redirected_to(conn) == "/"
    end

    test "renders for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/categories")
      assert html_response(conn, 200) =~ "Categories"
    end
  end
end
