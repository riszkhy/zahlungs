defmodule ZahlungsWeb.StoreLiveTest do
  @moduledoc """
  Store management (`/admin/stores`) and the login history (`/admin/logins`):
  access via `get/2`, behaviour by driving the LiveViews' callbacks.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Stores}
  alias ZahlungsWeb.{LoginLive, StoreLive}

  defp admin_fixture do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/admin/stores access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/stores")) == "/users/log_in"
    end

    test "redirects cashiers to /", %{conn: conn} do
      assert conn |> log_in_user(user_fixture()) |> get("/admin/stores") |> redirected_to() == "/"
    end

    test "lists the stores for admins, with a link in the navbar", %{conn: conn} do
      store = store_fixture(name: "Cabang Daftar", address: "Jl. Mawar 1")

      response =
        conn |> log_in_user(admin_fixture()) |> get("/admin/stores") |> html_response(200)

      assert response =~ "Cabang Daftar"
      assert response =~ store.code
      assert response =~ "Jl. Mawar 1"
      assert response =~ ~s(href="/admin/stores")
    end
  end

  describe "managing stores" do
    setup do
      %{admin: admin_fixture()}
    end

    test "creates a store from the form", %{admin: admin} do
      socket =
        StoreLive.Index
        |> mount_live(admin, action: :new)
        |> event("save", %{
          "store" => %{
            "name" => "Cabang Baru",
            "code" => "cb9",
            "address" => "Jl. Melati 2",
            "phone" => "021-555",
            "utc_offset_hours" => "8",
            "latitude" => "-6.2",
            "longitude" => "106.8"
          }
        })

      assert flash(socket, :info) == "Toko disimpan."
      assert live_redirect(socket) == "/admin/stores"

      store = Enum.find(Stores.list_stores(), &(&1.code == "CB9"))
      assert {store.name, store.utc_offset_hours, store.latitude} == {"Cabang Baru", 8, -6.2}
      assert store.id in Enum.map(socket.assigns.stores, & &1.id)
    end

    test "shows the errors and saves nothing when the form is invalid", %{admin: admin} do
      socket =
        StoreLive.Index
        |> mount_live(admin, action: :new)
        |> event("validate", %{"store" => %{"name" => "", "code" => "x y"}})

      assert socket.assigns.form.errors[:name]

      socket = event(socket, "save", %{"store" => %{"name" => "", "code" => "x y"}})

      assert socket.assigns.form.errors[:code]
      assert live_redirect(socket) == nil
      refute Enum.any?(Stores.list_stores(), &(&1.code == "X Y"))
      assert html(socket) =~ "2–8 huruf/angka"
    end

    test "edits a store", %{admin: admin} do
      store = store_fixture()

      socket =
        StoreLive.Index
        |> mount_live(admin, action: :edit, params: %{"id" => "#{store.id}"})
        |> event("save", %{"store" => %{"name" => "Nama Baru", "code" => store.code}})

      assert flash(socket, :info) == "Toko disimpan."
      assert Stores.get_store!(store.id).name == "Nama Baru"
    end

    test "deactivates and reactivates a store", %{admin: admin} do
      store = store_fixture()
      socket = mount_live(StoreLive.Index, admin)

      socket = event(socket, "toggle_active", %{"id" => store.id})
      refute Stores.get_store!(store.id).active
      assert flash(socket, :info) =~ "dinonaktifkan"

      event(socket, "toggle_active", %{"id" => "#{store.id}"})
      assert Stores.get_store!(store.id).active
    end

    test "the store the admin is working in cannot be deactivated", %{admin: admin} do
      socket =
        StoreLive.Index |> mount_live(admin) |> event("toggle_active", %{"id" => admin.store_id})

      assert flash(socket, :error) =~ "sedang Anda pakai"
      assert Stores.get_store!(admin.store_id).active
    end
  end

  describe "/admin/logins" do
    test "is for admins only", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/logins")) == "/users/log_in"
      assert conn |> log_in_user(user_fixture()) |> get("/admin/logins") |> redirected_to() == "/"
    end

    test "lists logins with who, where and how far from the store", %{conn: conn} do
      store = store_fixture(name: "Cabang Log", latitude: -6.175392, longitude: 106.827153)
      cashier = user_fixture(store_id: store.id)

      {:ok, _} =
        Accounts.record_login(cashier, %{"latitude" => "-6.194957", "longitude" => "106.823081"})

      {:ok, _} = Accounts.record_login(cashier)

      response =
        conn |> log_in_user(admin_fixture()) |> get("/admin/logins") |> html_response(200)

      assert response =~ "Riwayat login"
      assert response =~ cashier.email
      assert response =~ "Cabang Log"
      assert response =~ "2,2 km"
      assert response =~ "https://www.google.com/maps?q=-6.194957,106.823081"
      assert response =~ "tanpa lokasi"
    end

    test "filters by store and by user" do
      other_store = store_fixture()
      cashier = user_fixture()
      elsewhere = user_fixture(store_id: other_store.id)
      {:ok, mine} = Accounts.record_login(cashier)
      {:ok, theirs} = Accounts.record_login(elsewhere)

      socket = mount_live(LoginLive.Index, admin_fixture())

      by_store = event(socket, "filter", %{"store_id" => "#{other_store.id}", "user_id" => ""})
      assert Enum.map(by_store.assigns.logins, & &1.id) == [theirs.id]

      by_user = event(socket, "filter", %{"store_id" => "", "user_id" => "#{cashier.id}"})
      assert Enum.map(by_user.assigns.logins, & &1.id) == [mine.id]

      both =
        event(socket, "filter", %{"store_id" => "#{other_store.id}", "user_id" => "#{cashier.id}"})

      assert both.assigns.logins == []
    end
  end
end
