defmodule Zahlungs.StoresTest do
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Scope, Stores}

  defp admin_fixture(attrs \\ %{}) do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(attrs), "admin")
    admin
  end

  describe "create_store/1" do
    test "upcases the code and defaults to WIB and active" do
      assert {:ok, store} = Stores.create_store(%{name: "Cabang Bandung", code: " bdg1 "})
      assert store.code == "BDG1"
      assert store.utc_offset_hours == 7
      assert store.active
    end

    test "requires a name and a well-formed, unique code" do
      assert {:error, changeset} = Stores.create_store(%{name: "", code: "has space"})
      assert %{name: [_ | _], code: [_ | _]} = errors_on(changeset)

      existing = store_fixture()
      assert {:error, changeset} = Stores.create_store(%{name: "Dup", code: existing.code})
      assert %{code: ["has already been taken"]} = errors_on(changeset)
    end

    test "coordinates must be a valid pair" do
      assert {:error, changeset} = Stores.create_store(%{name: "A", code: "AA1", latitude: -6.2})
      assert %{longitude: [_ | _]} = errors_on(changeset)

      assert {:error, changeset} =
               Stores.create_store(%{name: "A", code: "AA1", latitude: 91, longitude: 181})

      assert %{latitude: [_ | _], longitude: [_ | _]} = errors_on(changeset)

      assert {:ok, _} =
               Stores.create_store(%{name: "A", code: "AA1", latitude: -6.2, longitude: 106.8})
    end
  end

  describe "active stores" do
    test "an inactive store is not offered and not returned by get_active_store/1" do
      store = store_fixture()
      assert store.id in Enum.map(Stores.list_active_stores(), & &1.id)

      {:ok, _} = Stores.set_store_active(store, false)

      refute store.id in Enum.map(Stores.list_active_stores(), & &1.id)
      refute {store.name, store.id} in Stores.store_options()
      assert Stores.get_active_store(store.id) == nil
      assert Stores.get_active_store(nil) == nil
      assert store.id in Enum.map(Stores.list_stores(), & &1.id)
    end
  end

  describe "Scope.for_user/2" do
    test "a cashier is bound to their own store, whatever is chosen" do
      other = store_fixture()
      cashier = user_fixture()

      scope = Scope.for_user(cashier, other.id)

      assert scope.store.id == cashier.store_id
      assert Scope.usable?(scope)
      refute Scope.admin?(scope)
      assert Scope.store_id(scope) == cashier.store_id
      assert Scope.for_user(cashier, "all").store.id == cashier.store_id
    end

    test "a cashier without an active store has no usable scope" do
      store = store_fixture()
      cashier = user_fixture(store_id: store.id)
      {:ok, _} = Stores.set_store_active(store, false)

      scope = Scope.for_user(cashier)

      assert scope.store == nil
      refute Scope.usable?(scope)
      assert_raise ArgumentError, fn -> Scope.store_id(scope) end
    end

    test "an admin gets the chosen store, their own by default, or all stores" do
      other = store_fixture()
      admin = admin_fixture()

      assert Scope.for_user(admin).store.id == admin.store_id
      assert Scope.for_user(admin, other.id).store.id == other.id

      all = Scope.for_user(admin, "all")
      assert all.store == nil
      assert Scope.usable?(all)
      assert Scope.store_id(all) == nil
    end

    test "an inactive or unknown store choice falls back to the admin default" do
      gone = store_fixture()
      {:ok, _} = Stores.set_store_active(gone, false)
      admin = admin_fixture()

      assert Scope.for_user(admin, gone.id).store.id == admin.store_id
      assert Scope.for_user(admin, -1).store.id == admin.store_id
    end

    test "no user, no scope" do
      assert Scope.for_user(nil) == nil
      refute Scope.usable?(nil)
    end
  end

  defp code, do: "W" <> Integer.to_string(System.unique_integer([:positive]), 36)

  describe "store code uniqueness" do
    test "a taken code is an error on the changeset, ignoring case and spaces" do
      existing = store_fixture()
      attrs = %{name: "Dup", code: " " <> String.downcase(existing.code) <> " "}

      changeset = Stores.change_store(%Zahlungs.Stores.Store{}, attrs)

      refute changeset.valid?
      assert %{code: ["has already been taken"]} = errors_on(changeset)
    end

    test "a store keeps its own code when edited" do
      store = store_fixture()

      assert Stores.change_store(store, %{name: "Renamed", code: store.code}).valid?
    end
  end

  describe "register_branch/2" do
    test "registers a store without a cashier" do
      code = code()

      assert {:ok, %{store: store, cashier: nil}} =
               Stores.register_branch(%{"name" => "Cabang A", "code" => code})

      assert Stores.get_active_store(store.id).code == code
    end

    test "registers the store and its first cashier together" do
      email = unique_user_email()

      assert {:ok, %{store: store, cashier: cashier}} =
               Stores.register_branch(
                 %{"name" => "Cabang B", "code" => code()},
                 %{"name" => "Kasir B", "email" => email, "password" => valid_user_password()}
               )

      assert {cashier.role, cashier.store_id} == {"cashier", store.id}
      assert cashier.confirmed_at
      assert Zahlungs.Accounts.get_user_by_email_and_password(email, valid_user_password())
      assert Scope.usable?(Scope.for_user(cashier))
    end

    test "accepts atom keys and ignores role and store_id from the caller" do
      other = store_fixture()

      assert {:ok, %{store: store, cashier: cashier}} =
               Stores.register_branch(
                 %{name: "Cabang C", code: code()},
                 %{
                   email: unique_user_email(),
                   password: valid_user_password(),
                   role: "admin",
                   store_id: other.id
                 }
               )

      assert {cashier.role, cashier.store_id} == {"cashier", store.id}
    end

    test "an invalid cashier saves nothing" do
      code = code()
      taken = user_fixture().email

      for cashier <- [
            %{"email" => unique_user_email(), "password" => "short"},
            %{"email" => taken, "password" => valid_user_password()},
            %{"name" => "", "email" => "", "password" => ""},
            %{}
          ] do
        assert {:error, :cashier, %Ecto.Changeset{}} =
                 Stores.register_branch(%{"name" => "Cabang D", "code" => code}, cashier)
      end

      refute Enum.any?(Stores.list_stores(), &(&1.code == code))
    end

    test "an invalid store saves nothing, cashier included" do
      existing = store_fixture()
      email = unique_user_email()

      assert {:error, :store, changeset} =
               Stores.register_branch(
                 %{"name" => "Cabang E", "code" => existing.code},
                 %{"email" => email, "password" => valid_user_password()}
               )

      assert %{code: [_ | _]} = errors_on(changeset)
      refute Zahlungs.Accounts.get_user_by_email(email)
    end
  end
end
