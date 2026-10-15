defmodule ZahlungsWeb.PageControllerTest do
  @moduledoc """
  `/` is Zahlungs' public landing page for visitors, and the way into the app
  for someone who is logged in.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  describe "GET / as a visitor" do
    test "shows the landing page, with the ways in", %{conn: conn} do
      response = conn |> get("/") |> html_response(200)

      assert response =~ "Kasir dan stok toko"
      assert response =~ ~s(href="/signup")
      assert response =~ ~s(href="/users/log_in")
    end

    test "is a page of its own: titled, described and in Indonesian", %{conn: conn} do
      response = conn |> get("/") |> html_response(200)

      assert response =~ ~s(lang="id")
      assert response =~ ~r{<title>[^<]*Zahlungs[^<]*</title>}
      assert response =~ ~s(<meta name="description" content="Zahlungs)
      assert response =~ ~s(property="og:title")
      refute response =~ "Phoenix Framework"
    end

    test "gives the contact details to reach us", %{conn: conn} do
      response = conn |> get("/") |> html_response(200)

      assert response =~ ~s(href="mailto:riszkhy@gmail.com")
      assert response =~ ~s(href="https://wa.me/628978844555)
    end

    test "says plainly what Zahlungs cannot do yet", %{conn: conn} do
      # Line breaks in the markup don't split a sentence here.
      response = conn |> get("/") |> html_response(200) |> String.replace(~r/\s+/, " ")

      # A shop pays for this: the page must not promise what isn't there.
      assert response =~ "Perlu internet?"
      assert response =~ "belum ada mode offline"
      assert response =~ "tidak diproses"
      assert response =~ "printer thermal belum tersedia"
    end

    test "loads nothing from another site", %{conn: conn} do
      response = conn |> get("/") |> html_response(200)

      refute response =~ ~r{(src|href)="https?://(?!wa\.me)}
      refute response =~ "unsplash"
    end

    test "is not the app's chrome: no menu, no store switcher", %{conn: conn} do
      response = conn |> get("/") |> html_response(200)

      refute response =~ ~s(id="menu-drawer")
      refute response =~ "Toko aktif"
    end
  end

  describe "GET / when logged in" do
    test "sends a cashier to the home screen", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/")

      assert redirected_to(conn) == "/home"
    end

    test "sends the platform operator on, to the platform", %{conn: conn} do
      conn = conn |> log_in_user(superadmin_fixture()) |> get("/")
      assert redirected_to(conn) == "/home"

      assert conn
             |> recycle()
             |> log_in_user(superadmin_fixture())
             |> get("/home")
             |> redirected_to() ==
               "/platform/organizations"
    end
  end
end
