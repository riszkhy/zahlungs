defmodule ZahlungsWeb.UserSessionControllerTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "GET /users/log_in" do
    test "renders log in page", %{conn: conn} do
      conn = get(conn, Routes.user_session_path(conn, :new))
      response = html_response(conn, 200)
      assert response =~ "Masuk</h3>"
      refute response =~ "Register"
      assert response =~ "Lupa password?"
      assert response =~ "Ingat saya"
      refute response =~ "Forgot password?"
      refute response =~ "Keep me logged in"
    end

    test "has the app's own look: no stock photo, titled for the app", %{conn: conn} do
      response = conn |> get(Routes.user_session_path(conn, :new)) |> html_response(200)

      # The photo came from another site, so it was missing on a shop's LAN
      # without internet.
      refute response =~ "unsplash"
      refute response =~ "background-image"
      refute response =~ "Phoenix Framework"
      assert response =~ ~r{<title[^>]*>\s*Masuk\s*· Zahlungs</title>}
      assert response =~ ~s(lang="id")
      assert response =~ "Kasir &amp; stok untuk toko Anda"
    end

    test "stays light when the device prefers a dark theme", %{conn: conn} do
      response = conn |> get(Routes.user_session_path(conn, :new)) |> html_response(200)

      # DaisyUI follows the device's dark preference unless a theme is pinned.
      assert response =~ ~s(data-theme="light")
    end

    test "redirects if already logged in", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(Routes.user_session_path(conn, :new))
      assert redirected_to(conn) == "/home"
    end
  end

  describe "GET /users/register" do
    test "self-registration is not available (accounts are created by an admin)", %{conn: conn} do
      assert conn |> get("/users/register") |> response(404)
    end
  end

  describe "POST /users/log_in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, Routes.user_session_path(conn, :create), %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) =~ "/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, "/home")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ "Profile"
      assert response =~ "Log out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, Routes.user_session_path(conn, :create), %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_zahlungs_web_user_remember_me"]
      assert redirected_to(conn) =~ "/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(Routes.user_session_path(conn, :create), %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
    end

    test "emits error message with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, Routes.user_session_path(conn, :create), %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      response = html_response(conn, 200)
      assert response =~ "Masuk</h3>"
      assert response =~ "Email atau password salah"
    end
  end

  describe "DELETE /users/log_out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(Routes.user_session_path(conn, :delete))
      assert redirected_to(conn) == "/users/log_in"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, Routes.user_session_path(conn, :delete))
      assert redirected_to(conn) == "/users/log_in"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
