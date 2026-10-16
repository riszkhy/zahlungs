defmodule Zahlungs.DepositsTest do
  @moduledoc """
  Deposit accounts (the owner's balances at a PPOB provider), the account each
  store sells services from, and what an account is estimated to hold.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.{Deposits, Services, Shifts, Stores}

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

    test "a name of spaces only is refused, not a crash" do
      account = deposit_account_fixture()

      assert {:error, changeset} = Deposits.update_account(account, %{name: "   "})
      assert errors_on(changeset)[:name]
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

  describe "deposit entries" do
    setup do
      account = deposit_account_fixture()
      assign_account(default_store(), account)
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

      %{account: account, admin: admin, cashier: user_on_shift_fixture()}
    end

    defp money(value), do: Decimal.new(value)

    defp assert_money(actual, expected),
      do: assert(Decimal.equal?(actual, money(expected)), "#{actual} ≠ #{expected}")

    defp product_costing(cost), do: service_product_fixture(%{cost: cost, margin_value: "1000"})

    # A top-up of 500.000 from outside the drawer; services costing 10.150
    # (done) and 50.150 (processing), and one of 26.000 that failed.
    defp sell_some(ctx) do
      {:ok, _} =
        Deposits.record_topup(ctx.admin, ctx.account, %{
          "amount" => "500000",
          "source" => "outside"
        })

      done = service_fixture(ctx.cashier, product_costing("10150"))
      {:ok, _} = Services.mark_success(done, ctx.cashier, nil)
      service_fixture(ctx.cashier, product_costing("50150"))
      failed = service_fixture(ctx.cashier, product_costing("26000"))
      {:ok, _} = Services.mark_failed(failed, ctx.cashier, "gagal")
    end

    test "the estimate is top-ups and corrections minus the cost of processing and successful services",
         ctx do
      sell_some(ctx)

      assert_money(Deposits.estimated_balance(ctx.account), "439700")
    end

    test "a top-up from the drawer is also a cash-out on the admin's shift", ctx do
      shift = shift_fixture(ctx.admin, "300000")

      assert {:ok, entry} =
               Deposits.record_topup(ctx.admin, ctx.account, %{
                 "amount" => "200000",
                 "source" => "drawer"
               })

      assert entry.cash_movement_id
      assert [movement] = Shifts.list_cash_movements(shift)
      assert {movement.category, movement.direction} == {"deposit_topup", "out"}
      assert_money(movement.amount, "200000")
      assert_money(Shifts.expected_cash(shift), "100000")
      assert_money(Deposits.estimated_balance(ctx.account), "200000")
    end

    test "a top-up from the drawer needs the admin's open shift", ctx do
      assert Deposits.record_topup(ctx.admin, ctx.account, %{
               "amount" => "200000",
               "source" => "drawer"
             }) ==
               {:error, :no_open_shift}

      assert Deposits.list_entries(ctx.account) == []
    end

    test "a top-up must be positive and say where the money came from", ctx do
      for attrs <- [
            %{"amount" => "0", "source" => "outside"},
            %{"amount" => "1000", "source" => "kas"}
          ] do
        assert {:error, %Ecto.Changeset{}} = Deposits.record_topup(ctx.admin, ctx.account, attrs)
      end
    end

    test "a correction needs a reason and may be negative", ctx do
      assert {:error, changeset} =
               Deposits.record_correction(ctx.admin, ctx.account, %{
                 "amount" => "-5000",
                 "note" => ""
               })

      assert errors_on(changeset)[:note]

      assert {:error, _} =
               Deposits.record_correction(ctx.admin, ctx.account, %{
                 "amount" => "0",
                 "note" => "nol"
               })

      assert {:ok, _} =
               Deposits.record_correction(ctx.admin, ctx.account, %{
                 "amount" => "-5000",
                 "note" => "selisih minggu lalu"
               })

      assert_money(Deposits.estimated_balance(ctx.account), "-5000")
    end

    test "reconciling records the difference, and the next one starts from there", ctx do
      sell_some(ctx)

      assert {:ok, entry} = Deposits.reconcile(ctx.admin, ctx.account, "430000", "cek sore")
      assert entry.kind == "correction"
      assert_money(entry.amount, "-9700")
      assert entry.note =~ "Pencocokan: saldo aplikasi Rp 430.000"
      assert entry.note =~ "cek sore"
      assert_money(Deposits.estimated_balance(ctx.account), "430000")

      assert Deposits.reconcile(ctx.admin, ctx.account, "430000") == {:ok, :matched}
      assert length(Deposits.list_entries(ctx.account)) == 2

      assert {:error, changeset} = Deposits.reconcile(ctx.admin, ctx.account, "-1")
      assert errors_on(changeset)[:actual_balance]
    end

    test "a store's account can change; old services stay with the old account", ctx do
      tx = service_fixture(ctx.cashier, product_costing("10150"))
      other = deposit_account_fixture()
      assign_account(default_store(), other)

      assert Repo.get!(Services.Transaction, tx.id).deposit_account_id == ctx.account.id
      assert_money(Deposits.estimated_balance(ctx.account), "-10150")
      assert_money(Deposits.estimated_balance(other), "0")

      {:ok, _} = Deposits.update_account(other, %{active: false})

      assert Services.record(ctx.cashier, service_product_fixture().id, %{
               "customer_ref" => "081234567890",
               "amount_paid" => "100000"
             }) == {:error, :no_deposit_account}
    end

    test "lists accounts with their estimate", ctx do
      sell_some(ctx)

      row = Enum.find(Deposits.list_accounts_with_balance(), &(&1.account.id == ctx.account.id))
      assert_money(row.balance, "439700")
    end

    test "another organization's entries are invisible" do
      other = organization_fixture()

      foreign =
        in_org(other, fn ->
          store = store_fixture()

          {:ok, admin} =
            Zahlungs.Accounts.set_user_role(user_fixture(%{store_id: store.id}), "admin")

          account = deposit_account_fixture()

          {:ok, _} =
            Deposits.record_correction(admin, account, %{"amount" => "1000", "note" => "awal"})

          account
        end)

      assert Deposits.list_entries(foreign) == []
    end
  end
end
