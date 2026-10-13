defmodule Zahlungs.LoginLogTest do
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, Geo}
  alias Zahlungs.Accounts.UserLogin

  describe "Geo.distance_m/2" do
    test "is zero for the same point and about 111 km per degree of latitude" do
      assert Geo.distance_m({-6.2, 106.8}, {-6.2, 106.8}) == 0.0
      assert_in_delta Geo.distance_m({0.0, 0.0}, {1.0, 0.0}), 111_195, 50
    end

    test "Monas to Bundaran HI is roughly 2.3 km" do
      monas = {-6.175392, 106.827153}
      bundaran_hi = {-6.194957, 106.823081}

      assert_in_delta Geo.distance_m(monas, bundaran_hi), 2_220, 150
    end
  end

  describe "set_user_store/2" do
    test "moves a cashier to another store" do
      other = store_fixture()
      cashier = user_fixture()

      assert {:ok, moved} = Accounts.set_user_store(cashier, other.id)
      assert moved.store_id == other.id
    end

    test "a cashier must have a store, an admin may have none" do
      cashier = user_fixture()
      assert {:error, changeset} = Accounts.set_user_store(cashier, nil)
      assert %{store_id: [_ | _]} = errors_on(changeset)

      {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
      assert {:ok, %{store_id: nil}} = Accounts.set_user_store(admin, nil)
    end

    test "create_user/1 requires a store for a cashier" do
      attrs = %{email: unique_user_email(), password: valid_user_password(), role: "cashier"}

      assert {:error, changeset} = Accounts.create_user(attrs)
      assert %{store_id: [_ | _]} = errors_on(changeset)

      assert {:ok, user} = Accounts.create_user(Map.put(attrs, :store_id, default_store().id))
      assert user.store_id == default_store().id

      assert {:ok, %{store_id: nil}} =
               Accounts.create_user(%{attrs | email: unique_user_email(), role: "admin"})
    end
  end

  describe "record_login/3" do
    test "stores the position, the distance to the user's store, and the client" do
      store = store_fixture(latitude: -6.175392, longitude: 106.827153)
      user = user_fixture(store_id: store.id)

      position = %{"latitude" => "-6.194957", "longitude" => "106.823081", "accuracy" => "25"}
      meta = %{ip: "203.0.113.7", user_agent: String.duplicate("x", 400)}

      assert {:ok, %UserLogin{} = login} = Accounts.record_login(user, position, meta)

      assert login.user_id == user.id
      assert login.store_id == store.id
      assert_in_delta login.latitude, -6.194957, 0.000001
      assert_in_delta login.longitude, 106.823081, 0.000001
      assert login.accuracy_m == 25.0
      assert_in_delta login.distance_m, 2_220, 150
      assert login.ip == "203.0.113.7"
      assert String.length(login.user_agent) == 255
    end

    test "a login without a position is still recorded" do
      user = user_fixture()

      assert {:ok, login} = Accounts.record_login(user)

      assert login.store_id == user.store_id

      assert {login.latitude, login.longitude, login.accuracy_m, login.distance_m} ==
               {nil, nil, nil, nil}
    end

    test "nonsense coordinates are dropped rather than stored" do
      user = user_fixture()

      for position <- [
            %{"latitude" => "91", "longitude" => "10"},
            %{"latitude" => "10", "longitude" => "181"},
            %{"latitude" => "abc", "longitude" => "10"},
            %{"latitude" => "10"},
            %{"latitude" => "10; DROP", "longitude" => "10"}
          ] do
        assert {:ok, login} = Accounts.record_login(user, Map.put(position, "accuracy", "5"))
        assert {login.latitude, login.longitude, login.accuracy_m} == {nil, nil, nil}
      end
    end

    test "no distance when the store has no coordinates; a negative accuracy is dropped" do
      user = user_fixture()

      assert {:ok, login} =
               Accounts.record_login(user, %{
                 "latitude" => -6.2,
                 "longitude" => 106.8,
                 "accuracy" => "-3"
               })

      assert login.latitude == -6.2
      assert login.distance_m == nil
      assert login.accuracy_m == nil
    end
  end

  describe "list_user_logins/1 and prune_user_logins/1" do
    test "lists most recent first and filters by user and store" do
      other_store = store_fixture()
      user = user_fixture()
      other = user_fixture(store_id: other_store.id)

      {:ok, first} = Accounts.record_login(user)
      {:ok, second} = Accounts.record_login(user)
      {:ok, elsewhere} = Accounts.record_login(other)

      assert Enum.map(Accounts.list_user_logins(user_id: user.id), & &1.id) ==
               [second.id, first.id]

      assert [%{id: id, user: %{email: email}, store: %{id: store_id}}] =
               Accounts.list_user_logins(store_id: other_store.id)

      assert {id, email, store_id} == {elsewhere.id, other.email, other_store.id}
      assert length(Accounts.list_user_logins(user_id: user.id, limit: 1)) == 1
    end

    test "prune removes only rows older than the retention period" do
      user = user_fixture()
      {:ok, old} = Accounts.record_login(user)
      {:ok, recent} = Accounts.record_login(user)

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -91 * 86_400)

      Repo.update_all(from(l in UserLogin, where: l.id == ^old.id),
        set: [inserted_at: NaiveDateTime.truncate(long_ago, :second)]
      )

      assert Accounts.prune_user_logins(90) >= 1
      assert Enum.map(Accounts.list_user_logins(user_id: user.id), & &1.id) == [recent.id]
    end
  end
end
