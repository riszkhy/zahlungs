defmodule ZahlungsWeb.CashierLiveTest do
  @moduledoc """
  Access + initial-render tests for the cashier page via `get/2` (no lazy_html).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  describe "/cashier" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/cashier")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "renders for authenticated users", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/cashier")
      response = html_response(conn, 200)
      assert response =~ "Cashier"
      assert response =~ "Cart"
    end
  end
end
