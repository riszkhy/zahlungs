defmodule ZahlungsWeb.SignupControllerTest do
  @moduledoc "Public sign-up, and who may log in while an organization awaits or loses approval."
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures

  alias Zahlungs.{Accounts, Organizations}

  @password "rahasia-sekali-123"

  # Each test signs up from an address of its own, so the sign-up throttle of
  # one test never counts against another.
  defp from_new_address(conn) do
    n = System.unique_integer([:positive])
    %{conn | remote_ip: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}}
  end

  defp signup_params(overrides \\ %{}) do
    Map.merge(
      %{
        "business_name" => "Toko Daftar #{System.unique_integer([:positive])}",
        "phone" => "0812-2222",
        "name" => "Pak Budi",
        "email" => unique_user_email(),
        "password" => @password
      },
      overrides
    )
  end

  defp sign_up(conn, params) do
    conn |> from_new_address() |> post("/signup", %{"signup" => params})
  end

  defp organization_named(name) do
    Enum.find(Organizations.list_organizations(), &(&1.organization.name == name)).organization
  end

  defp log_in(conn, email) do
    post(conn, "/users/log_in", %{"user" => %{"email" => email, "password" => @password}})
  end

  describe "GET /signup" do
    test "shows the form to guests, linked from the log in page", %{conn: conn} do
      response = conn |> get("/signup") |> html_response(200)

      assert response =~ "Daftarkan bisnis Anda"
      assert response =~ ~s(name="signup[business_name]")
      assert response =~ ~s(name="signup[email]")

      assert conn |> get("/users/log_in") |> html_response(200) =~ ~s(href="/signup")
    end

    test "sends someone already logged in to their home", %{conn: conn} do
      assert conn |> log_in_user(user_fixture()) |> get("/signup") |> redirected_to() == "/home"
    end
  end

  describe "POST /signup" do
    test "registers the business as pending and does not log anyone in", %{conn: conn} do
      params = signup_params()

      conn = sign_up(conn, params)

      assert redirected_to(conn) == "/signup/pending"
      refute get_session(conn, :user_token)
      assert organization_named(params["business_name"]).status == "pending"
      assert conn |> get("/signup/pending") |> html_response(200) =~ "menunggu verifikasi"
    end

    test "shows the errors and registers nothing when the form is invalid", %{conn: conn} do
      params = signup_params(%{"email" => "bukan-email", "password" => "pendek"})

      response = conn |> sign_up(params) |> html_response(200)

      assert response =~ "must have the @ sign and no spaces"
      assert response =~ "should be at least 12 character"

      refute Enum.any?(
               Organizations.list_organizations(),
               &(&1.organization.name == params["business_name"])
             )
    end

    test "refuses an email that already has an account", %{conn: conn} do
      taken = user_fixture().email

      response = conn |> sign_up(signup_params(%{"email" => taken})) |> html_response(200)

      assert response =~ "has already been taken"
    end

    test "slows down repeated sign-ups from one address", %{conn: conn} do
      conn = from_new_address(conn)
      post = fn -> post(conn, "/signup", %{"signup" => signup_params()}) end

      for _ <- 1..5, do: assert(redirected_to(post.()) == "/signup/pending")

      assert post.() |> html_response(200) =~ "Terlalu banyak pendaftaran"
    end
  end

  describe "logging in before and after review" do
    setup %{conn: conn} do
      params = signup_params()
      sign_up(conn, params)

      %{
        email: params["email"],
        org: organization_named(params["business_name"]),
        operator: superadmin_fixture()
      }
    end

    test "a pending owner is told to wait", %{conn: conn, email: email} do
      conn = log_in(conn, email)

      assert html_response(conn, 200) =~ "menunggu verifikasi"
      refute get_session(conn, :user_token)
      assert Accounts.list_user_logins(user_id: Accounts.get_user_by_email(email).id) == []
    end

    test "an approved owner gets in and lands on home with their own store", ctx do
      {:ok, _} = Organizations.set_status(ctx.org, "active", ctx.operator)

      conn = log_in(ctx.conn, ctx.email)

      assert redirected_to(conn) == "/home"
      assert conn |> get("/home") |> html_response(200) =~ "Toko Utama"
    end

    test "a rejected or suspended owner is told so", ctx do
      {:ok, rejected} = Organizations.set_status(ctx.org, "rejected", ctx.operator)
      assert ctx.conn |> log_in(ctx.email) |> html_response(200) =~ "tidak disetujui"

      {:ok, active} = Organizations.set_status(rejected, "active", ctx.operator)
      {:ok, _} = Organizations.set_status(active, "suspended", ctx.operator)
      assert ctx.conn |> log_in(ctx.email) |> html_response(200) =~ "ditangguhkan"
    end

    test "suspension ends a session that was already open", ctx do
      {:ok, active} = Organizations.set_status(ctx.org, "active", ctx.operator)
      conn = log_in(ctx.conn, ctx.email)
      assert conn |> get("/home") |> html_response(200)

      {:ok, _} = Organizations.set_status(active, "suspended", ctx.operator)
      conn = get(conn, "/home")

      assert redirected_to(conn) == "/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "ditangguhkan"
      refute get_session(conn, :user_token)
    end
  end
end
