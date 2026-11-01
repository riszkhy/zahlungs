defmodule Zahlungs.ServicesHistoryTest do
  @moduledoc """
  The list of services behind the Riwayat layanan page: every service of the
  scope's store(s), whoever recorded it, whatever its status, with its filters.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Transaction

  setup do
    assign_account(default_store(), deposit_account_fixture())
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

    %{
      admin: admin,
      cashier: user_on_shift_fixture(),
      colleague: user_on_shift_fixture(),
      pulsa: service_product_fixture(),
      today: Zahlungs.LocalTime.today()
    }
  end

  defp ids(scope, opts \\ []), do: scope |> Services.list_transactions(opts) |> Enum.map(& &1.id)

  describe "the scope" do
    test "a cashier sees every service of their store, a colleague's too", ctx do
      mine = service_fixture(ctx.cashier, ctx.pulsa)
      theirs = service_fixture(ctx.colleague, ctx.pulsa)

      assert ids(scope(ctx.cashier)) == [theirs.id, mine.id]
    end

    test "one store, all stores of the organization, never another organization", ctx do
      here = service_fixture(ctx.cashier, ctx.pulsa)

      other_store = store_fixture()
      assign_account(other_store, deposit_account_fixture())
      elsewhere = user_on_shift_fixture(%{store_id: other_store.id})
      there = service_fixture(elsewhere, ctx.pulsa)

      foreign =
        in_org(organization_fixture(), fn ->
          foreign_store = store_fixture()
          assign_account(foreign_store, deposit_account_fixture())
          foreigner = user_on_shift_fixture(%{store_id: foreign_store.id})
          service_fixture(foreigner, service_product_fixture())
        end)

      assert ids(scope(ctx.cashier)) == [here.id]
      assert there.id in ids(all_stores_scope(ctx.admin))
      assert here.id in ids(all_stores_scope(ctx.admin))
      refute foreign.id in ids(all_stores_scope(ctx.admin))
      assert Services.count_transactions(all_stores_scope(ctx.admin)) == 2
    end

    test "brings who recorded it and where", ctx do
      service_fixture(ctx.cashier, ctx.pulsa)

      assert [tx] = Services.list_transactions(scope(ctx.cashier))
      assert tx.user.id == ctx.cashier.id
      assert tx.store.id == default_store().id
    end
  end

  describe "the filters" do
    test "by status", ctx do
      processing = service_fixture(ctx.cashier, ctx.pulsa)

      {:ok, success} =
        Services.mark_success(service_fixture(ctx.cashier, ctx.pulsa), ctx.cashier, nil)

      {:ok, failed} =
        Services.mark_failed(service_fixture(ctx.cashier, ctx.pulsa), ctx.cashier, "gagal")

      scope = store_scope()
      assert ids(scope, status: "processing") == [processing.id]
      assert ids(scope, status: "success") == [success.id]
      assert ids(scope, status: "failed") == [failed.id]
      assert length(ids(scope, status: "")) == 3
      assert Services.count_transactions(scope, status: "failed") == 1
    end

    test "by category", ctx do
      pulsa = service_fixture(ctx.cashier, ctx.pulsa)
      token = service_fixture(ctx.cashier, service_product_fixture(%{category: "token_pln"}))

      assert ids(store_scope(), category: "token_pln") == [token.id]
      assert ids(store_scope(), category: "pulsa") == [pulsa.id]
      assert length(ids(store_scope(), category: "")) == 2
    end

    test "the days are the store's local days", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      {start, _finish} = Zahlungs.LocalTime.day_range(ctx.today, ctx.today, default_store())
      yesterday = Date.add(ctx.today, -1)
      on = fn day -> ids(store_scope(), date_from: day, date_to: day) end

      # The first second of the local day (the evening before, in UTC) is today.
      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [inserted_at: start])
      assert {on.(ctx.today), on.(yesterday)} == {[tx.id], []}

      # One second earlier is yesterday.
      earlier = NaiveDateTime.add(start, -1)
      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [inserted_at: earlier])
      assert {on.(ctx.today), on.(yesterday)} == {[], [tx.id]}

      assert ids(store_scope(), date_from: yesterday, date_to: ctx.today) == [tx.id]
    end

    test "searches the number however it is typed, and the code", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa, %{"customer_ref" => "081234567890"})
      other = service_fixture(ctx.cashier, ctx.pulsa, %{"customer_ref" => "085711112222"})

      assert ids(store_scope(), search: "081234567890") == [tx.id]
      assert ids(store_scope(), search: "4567") == [tx.id]
      assert ids(store_scope(), search: " 0812-3456.7890 ") == [tx.id]
      assert ids(store_scope(), search: other.code) == [other.id]
      assert ids(store_scope(), search: String.downcase(other.code)) == [other.id]
      assert length(ids(store_scope(), search: "  ")) == 2
      assert Services.count_transactions(store_scope(), search: "4567") == 1
    end

    test "a search is text, not a pattern", ctx do
      service_fixture(ctx.cashier, ctx.pulsa)

      for pattern <- ["%", "_", "0812%", "\\"] do
        assert ids(store_scope(), search: pattern) == []
      end
    end

    test "filters combine", ctx do
      {:ok, success} =
        Services.mark_success(service_fixture(ctx.cashier, ctx.pulsa), ctx.cashier, nil)

      service_fixture(ctx.cashier, ctx.pulsa)
      service_fixture(ctx.cashier, service_product_fixture(%{category: "token_pln"}))

      assert ids(store_scope(),
               status: "success",
               category: "pulsa",
               search: "0812",
               date_from: ctx.today,
               date_to: ctx.today
             ) == [success.id]
    end
  end

  test "pages, newest first", ctx do
    [first, second, third] = for _ <- 1..3, do: service_fixture(ctx.cashier, ctx.pulsa)

    assert ids(store_scope(), limit: 2) == [third.id, second.id]
    assert ids(store_scope(), limit: 2, offset: 2) == [first.id]
    assert Services.count_transactions(store_scope()) == 3
  end
end
