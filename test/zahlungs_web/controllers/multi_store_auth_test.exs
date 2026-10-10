defmodule ZahlungsWeb.MultiStoreAuthTest do
  @moduledoc """
  Logging in across stores: who is let in, the login log, the failed-login
  throttle, and the admin's store switcher.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, Stores}

  defp admin_fixture do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp log_in(conn, user, extra \\ %{}) do
    params = Map.merge(%{"email" => user.email, "password" => valid_user_password()}, extra)
    post(conn, "/users/log_in", %{"user" => params})
  end

  describe "login page" do
    test "carries the position fields and tells staff their location is recorded", %{conn: conn} do
      response = conn |> get("/users/log_in") |> html_response(200)

      assert response =~ ~s(name="user[latitude]")
      assert response =~ ~s(name="user[longitude]")
      assert response =~ ~s(name="user[accuracy]")
      assert response =~ "Lokasi login dicatat"
    end
  end

  describe "who is let in" do
    test "a cashier whose store was deactivated cannot log in", %{conn: conn} do
      store = store_fixture()
      cashier = user_fixture(store_id: store.id)
      {:ok, _} = Stores.set_store_active(store, false)

      conn = log_in(conn, cashier)

      assert html_response(conn, 200) =~ "belum ditempatkan di toko aktif"
      refute get_session(conn, :user_token)
      assert Accounts.list_user_logins(user_id: cashier.id) == []
    end

    test "a logged-in cashier is logged out once their store is deactivated", %{conn: conn} do
      store = store_fixture()
      cashier = user_fixture(store_id: store.id)
      conn = log_in_user(conn, cashier)
      assert conn |> get("/home") |> html_response(200)

      {:ok, _} = Stores.set_store_active(store, false)
      conn = get(conn, "/home")

      assert redirected_to(conn) == "/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "belum ditempatkan di toko aktif"
      refute get_session(conn, :user_token)
    end

    test "an admin without a store can still log in", %{conn: conn} do
      {:ok, admin} = Accounts.set_user_store(admin_fixture(), nil)

      assert redirected_to(log_in(conn, admin)) == "/home"
    end
  end

  describe "login log" do
    test "a login is recorded with the position the browser sent", %{conn: conn} do
      cashier = user_fixture()

      conn =
        conn
        |> put_req_header("user-agent", "TestBrowser/1.0")
        |> log_in(cashier, %{"latitude" => "-6.2", "longitude" => "106.8", "accuracy" => "12"})

      assert redirected_to(conn) == "/home"

      assert [login] = Accounts.list_user_logins(user_id: cashier.id)
      assert {login.latitude, login.longitude, login.accuracy_m} == {-6.2, 106.8, 12.0}
      assert login.store_id == cashier.store_id
      assert login.ip == "127.0.0.1"
      assert login.user_agent == "TestBrowser/1.0"
    end

    test "a login without a position works and is recorded too", %{conn: conn} do
      cashier = user_fixture()

      assert redirected_to(log_in(conn, cashier, %{"latitude" => "", "longitude" => ""})) ==
               "/home"

      assert [%{latitude: nil, longitude: nil}] = Accounts.list_user_logins(user_id: cashier.id)
    end

    test "a wrong password records nothing", %{conn: conn} do
      cashier = user_fixture()

      conn = log_in(conn, cashier, %{"password" => "not the password"})

      assert html_response(conn, 200) =~ "Invalid email or password"
      assert Accounts.list_user_logins(user_id: cashier.id) == []
    end
  end

  describe "failed-login throttle" do
    test "after five wrong passwords even the right one is refused for a while", %{conn: conn} do
      cashier = user_fixture()
      other = user_fixture()

      for _ <- 1..5 do
        assert conn |> log_in(cashier, %{"password" => "wrong"}) |> html_response(200) =~
                 "Invalid email or password"
      end

      blocked = log_in(conn, cashier)
      assert html_response(blocked, 200) =~ "Terlalu banyak percobaan"
      refute get_session(blocked, :user_token)

      # Someone else is not affected.
      assert redirected_to(log_in(conn, other)) == "/home"
    end

    test "a successful login clears the earlier failures", %{conn: conn} do
      cashier = user_fixture()

      for _ <- 1..4, do: log_in(conn, cashier, %{"password" => "wrong"})
      assert redirected_to(log_in(conn, cashier)) == "/home"

      for _ <- 1..4, do: log_in(conn, cashier, %{"password" => "wrong"})
      assert redirected_to(log_in(conn, cashier)) == "/home"
    end
  end

  describe "store switcher" do
    test "an admin picks a store and the choice sticks for later requests", %{conn: conn} do
      other = store_fixture(name: "Cabang Lain")

      conn =
        conn |> log_in_user(admin_fixture()) |> post("/stores/select", %{"store_id" => other.id})

      assert redirected_to(conn) == "/home"
      assert get_session(conn, :store_id) == other.id

      conn = get(conn, "/home")
      assert conn.assigns.current_scope.store.id == other.id
    end

    test "an admin can look at all stores at once", %{conn: conn} do
      conn =
        conn |> log_in_user(admin_fixture()) |> post("/stores/select", %{"store_id" => "all"})

      assert get_session(conn, :store_id) == "all"
      assert get(conn, "/home").assigns.current_scope.store == nil
    end

    test "returns to the page the admin was on", %{conn: conn} do
      other = store_fixture()

      conn =
        conn
        |> log_in_user(admin_fixture())
        |> post("/stores/select", %{"store_id" => other.id, "return_to" => "/sales"})

      assert redirected_to(conn) == "/sales"

      # Only local paths: no bouncing to another site.
      conn = post(conn, "/stores/select", %{"store_id" => other.id, "return_to" => "//evil.test"})
      assert redirected_to(conn) == "/home"
    end

    test "an unknown or inactive store is not accepted", %{conn: conn} do
      gone = store_fixture()
      {:ok, _} = Stores.set_store_active(gone, false)
      admin = admin_fixture()

      conn = conn |> log_in_user(admin) |> post("/stores/select", %{"store_id" => gone.id})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Toko tidak ditemukan"
      assert get_session(conn, :store_id) == nil
    end

    test "a cashier cannot switch stores", %{conn: conn} do
      other = store_fixture()
      cashier = user_fixture()

      conn = conn |> log_in_user(cashier) |> post("/stores/select", %{"store_id" => other.id})

      assert redirected_to(conn) == "/"
      assert get(conn, "/home").assigns.current_scope.store.id == cashier.store_id
    end
  end

  describe "navbar" do
    test "an admin gets the switcher with every active store and all stores", %{conn: conn} do
      other = store_fixture(name: "Cabang Navbar")
      response = conn |> log_in_user(admin_fixture()) |> get("/home") |> html_response(200)

      assert response =~ ~s(action="/stores/select")
      assert response =~ other.name
      assert response =~ "Semua toko"
    end

    test "a cashier sees their store's name and no switcher", %{conn: conn} do
      store = store_fixture(name: "Cabang Kasir")

      response =
        conn
        |> log_in_user(user_fixture(store_id: store.id))
        |> get("/home")
        |> html_response(200)

      assert response =~ "Cabang Kasir"
      refute response =~ ~s(action="/stores/select")
    end
  end
end
