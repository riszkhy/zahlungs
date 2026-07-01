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

    test "prompts to open a shift when the cashier has none", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/cashier")
      response = html_response(conn, 200)
      assert response =~ "Cashier"
      assert response =~ "Open shift"
      refute response =~ ">Cart<"
    end

    test "shows the cart once a shift is open", %{conn: conn} do
      user = user_fixture()
      {:ok, _shift} = Zahlungs.Shifts.open_shift(user, 100_000)

      conn = conn |> log_in_user(user) |> get("/cashier")
      response = html_response(conn, 200)
      assert response =~ "Cart"
      assert response =~ "Close shift"
    end
  end
end
