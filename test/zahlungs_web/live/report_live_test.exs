defmodule ZahlungsWeb.ReportLiveTest do
  @moduledoc "Access-control + render tests for the sales report via get/2 (no lazy_html)."
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/reports/sales access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/reports/sales")) == "/users/log_in"
    end

    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/sales")
      assert redirected_to(conn) == "/"
    end

    test "renders the report for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/reports/sales")
      response = html_response(conn, 200)
      assert response =~ "Sales Report"
      assert response =~ "Gross profit"
      assert response =~ "Sales by category"
    end
  end

  describe "/reports/stock access control" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/reports/stock")
      assert redirected_to(conn) == "/"
    end

    test "renders the stock report for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/reports/stock")
      response = html_response(conn, 200)
      assert response =~ "Stock Report"
      assert response =~ "Out of stock"
    end
  end
end
