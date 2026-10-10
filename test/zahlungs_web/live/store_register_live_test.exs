defmodule ZahlungsWeb.StoreRegisterLiveTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Stores}
  alias ZahlungsWeb.StoreLive

  defp admin_fixture do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp code, do: "W" <> Integer.to_string(System.unique_integer([:positive]), 36)

  defp store_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Cabang Wizard",
        "code" => code(),
        "address" => "Jl. Anggrek 3",
        "phone" => "",
        "utc_offset_hours" => "8",
        "latitude" => "",
        "longitude" => ""
      },
      overrides
    )
  end

  defp cashier_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Kasir Wizard",
        "email" => unique_user_email(),
        "password" => valid_user_password()
      },
      overrides
    )
  end

  defp store_with(code), do: Enum.find(Stores.list_stores(), &(&1.code == code))

  defp on_step_two(store \\ store_params()) do
    StoreLive.Register
    |> mount_live(admin_fixture(), action: :new)
    |> event("next", %{"store" => store})
  end

  describe "access" do
    test "guests go to log in, cashiers to /, admins see step 1", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/stores/register")) == "/users/log_in"

      assert conn
             |> log_in_user(user_fixture())
             |> get("/admin/stores/register")
             |> redirected_to() ==
               "/"

      response =
        conn
        |> log_in_user(admin_fixture())
        |> get("/admin/stores/register")
        |> html_response(200)

      assert response =~ "Langkah 1 dari 2 — Data toko"
      assert response =~ ~s(href="/admin/stores/register")
      assert response =~ "Daftar Cabang"
    end
  end

  describe "step 1" do
    test "valid store data moves to step 2 without saving anything" do
      params = store_params()
      socket = on_step_two(params)

      assert socket.assigns.step == :cashier
      assert html(socket) =~ "Langkah 2 dari 2 — Kasir pertama (opsional)"
      assert html(socket) =~ "Cabang Wizard"
      refute store_with(params["code"])
    end

    test "invalid store data stays on step 1 with the errors" do
      taken = store_fixture().code

      for {bad, field} <- [
            {%{"name" => ""}, :name},
            {%{"code" => String.downcase(taken)}, :code},
            {%{"latitude" => "-6.2"}, :longitude}
          ] do
        socket = on_step_two(store_params(bad))

        assert socket.assigns.step == :store
        assert socket.assigns.store_form.errors[field]
        assert html(socket) =~ "Langkah 1 dari 2 — Data toko"
      end
    end

    test "validate_store shows errors while typing" do
      socket =
        StoreLive.Register
        |> mount_live(admin_fixture(), action: :new)
        |> event("validate_store", %{"store" => store_params(%{"code" => "x y"})})

      assert socket.assigns.step == :store
      assert socket.assigns.store_form.errors[:code]
    end

    test "save and skip do nothing before step 2" do
      socket = mount_live(StoreLive.Register, admin_fixture(), action: :new)
      before = length(Stores.list_stores())

      assert event(socket, "skip").assigns.step == :store
      assert event(socket, "save", %{"user" => cashier_params()}).assigns.step == :store
      assert length(Stores.list_stores()) == before
    end
  end

  describe "step 2" do
    test "back returns to step 1 with the store and cashier data kept" do
      params = store_params()
      cashier = cashier_params()

      socket =
        params
        |> on_step_two()
        |> event("validate_cashier", %{"user" => cashier})
        |> event("back")

      assert socket.assigns.step == :store
      assert socket.assigns.store_form[:name].value == "Cabang Wizard"
      assert socket.assigns.store_form[:code].value == params["code"]

      socket = event(socket, "next", %{"store" => params})
      assert socket.assigns.cashier_form[:email].value == cashier["email"]
    end

    test "skip registers the store alone, ignoring what was typed for the cashier" do
      params = store_params()
      cashier = cashier_params()

      socket =
        params
        |> on_step_two()
        |> event("validate_cashier", %{"user" => cashier})
        |> event("skip")

      store = store_with(params["code"])

      assert {store.name, store.utc_offset_hours, store.address} ==
               {"Cabang Wizard", 8, "Jl. Anggrek 3"}

      refute Accounts.get_user_by_email(cashier["email"])
      assert live_redirect(socket) == "/admin/stores"

      assert flash(socket, :info) ==
               "Cabang Cabang Wizard terdaftar. Stoknya masih 0 — pilih cabang ini di menu atas, lalu isi stok lewat Products."
    end

    test "save registers the store and a cashier who can log in there" do
      params = store_params()
      cashier = cashier_params()

      socket = params |> on_step_two() |> event("save", %{"user" => cashier})

      store = store_with(params["code"])
      user = Accounts.get_user_by_email_and_password(cashier["email"], cashier["password"])
      assert {user.role, user.store_id, user.name} == {"cashier", store.id, "Kasir Wizard"}
      assert live_redirect(socket) == "/admin/stores"
    end

    test "a cashier error keeps step 2 and saves no store" do
      params = store_params()
      taken = user_fixture().email

      for bad <- [
            %{"email" => taken},
            %{"password" => "short"},
            %{"email" => "", "password" => ""}
          ] do
        socket = params |> on_step_two() |> event("save", %{"user" => cashier_params(bad)})

        assert socket.assigns.step == :cashier
        assert socket.assigns.cashier_form.errors != []
        assert live_redirect(socket) == nil
      end

      refute store_with(params["code"])
    end

    test "a code taken between step 1 and saving sends the admin back to step 1" do
      params = store_params()
      socket = on_step_two(params)
      store_fixture(code: params["code"])

      socket = event(socket, "skip")

      assert socket.assigns.step == :store
      assert socket.assigns.store_form.errors[:code]
    end
  end
end
