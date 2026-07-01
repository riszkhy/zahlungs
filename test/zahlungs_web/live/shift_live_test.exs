defmodule ZahlungsWeb.ShiftLiveTest do
  @moduledoc "Shift history tested via get/2 (no lazy_html)."
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  alias Zahlungs.Shifts

  describe "/shifts" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/shifts")) == "/users/log_in"
    end

    test "lists the cashier's own shifts and shows their name", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Zahlungs.Accounts.update_user_name(user, %{name: "Budi Kasir"})
      user = Zahlungs.Accounts.get_user!(user.id)
      {:ok, shift} = Shifts.open_shift(user, 100_000)

      conn = conn |> log_in_user(user) |> get("/shifts")
      response = html_response(conn, 200)
      assert response =~ "Shifts"
      assert response =~ "Budi Kasir"
      assert response =~ Integer.to_string(shift.id)
    end
  end
end
