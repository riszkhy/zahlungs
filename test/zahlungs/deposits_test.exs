defmodule Zahlungs.DepositsTest do
  @moduledoc """
  Deposit accounts (the owner's balances at a PPOB provider), the account each
  store sells services from, and what an account is estimated to hold.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.{Deposits, Stores}

  describe "accounts" do
    test "creates and renames an account; names are unique per organization" do
      name = "Pusat #{System.unique_integer([:positive])}"

      assert {:ok, account} = Deposits.create_account(%{name: name})
      assert account.active

      assert {:error, changeset} = Deposits.create_account(%{name: name})
      assert errors_on(changeset)[:name]

      other = organization_fixture()
      assert {:ok, _} = in_org(other, fn -> Deposits.create_account(%{name: name}) end)

      assert {:ok, renamed} = Deposits.update_account(account, %{name: name <> " baru"})
      assert renamed.name == name <> " baru"
    end

    test "another organization's accounts are invisible" do
      other = in_org(organization_fixture(), fn -> deposit_account_fixture() end)

      refute other.id in Enum.map(Deposits.list_accounts(), & &1.id)
      assert_raise Ecto.NoResultsError, fn -> Deposits.get_account!(other.id) end
    end

    test "account_options lists active accounts only" do
      active = deposit_account_fixture()
      inactive = deposit_account_fixture(%{active: false})
      ids = Enum.map(Deposits.account_options(), fn {_name, id} -> id end)

      assert active.id in ids
      refute inactive.id in ids
      assert Deposits.active_account?(active.id)
      refute Deposits.active_account?(inactive.id)
      refute Deposits.active_account?(nil)
    end
  end

  describe "a store's account" do
    test "a store takes only an active account of its own organization" do
      store = default_store()
      active = deposit_account_fixture()
      inactive = deposit_account_fixture(%{active: false})
      foreign = in_org(organization_fixture(), fn -> deposit_account_fixture() end)

      assert {:ok, store} = Stores.update_store(store, %{deposit_account_id: active.id})
      assert store.deposit_account_id == active.id

      for account <- [inactive, foreign] do
        assert {:error, changeset} = Stores.update_store(store, %{deposit_account_id: account.id})
        assert "akun deposit tidak aktif" in errors_on(changeset).deposit_account_id
      end

      assert {:ok, store} = Stores.update_store(store, %{deposit_account_id: nil})
      assert is_nil(store.deposit_account_id)
    end
  end
end
