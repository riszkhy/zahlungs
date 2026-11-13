defmodule ZahlungsWeb.MdTopBarTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  test "the top bar uses the MD3 surface, keeps its navigation and menu", %{conn: conn} do
    html = conn |> log_in_user(user_fixture()) |> get("/cashier") |> html_response(200)

    [header | _] = Regex.run(~r/<header[^>]*>/, html)
    assert header =~ "bg-surface-container"
    assert header =~ "text-on-surface"
    refute header =~ "bg-green-700"

    assert html =~ ~s(id="primary-nav")
    assert html =~ ~s(aria-label="Buka menu")
    assert html =~ ~r/class="[^"]*text-primary[^"]*"[^>]*>\s*Zahlungs/
  end
end
