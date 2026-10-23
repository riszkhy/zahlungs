defmodule Zahlungs.ServicesTest do
  @moduledoc """
  PPOB services (Fase 0): products and their price, recording a service when
  the money is taken, and marking it done or failed.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Product

  defp d(value), do: Decimal.new(value)

  defp product(attrs), do: struct(Product, Map.new(attrs))

  defp assert_price(result, price, cost) do
    assert {:ok, %{price: got_price, cost: got_cost}} = result
    assert Decimal.equal?(got_price, d(price)), "price #{got_price}, expected #{price}"
    assert Decimal.equal?(got_cost, d(cost)), "cost #{got_cost}, expected #{cost}"
  end

  describe "price_for/2" do
    test "a fixed-value product is its cost plus a rupiah margin" do
      token =
        product(
          category: "token_pln",
          cost: d("50150"),
          margin_type: "amount",
          margin_value: d("2350")
        )

      assert_price(Services.price_for(token, nil), "52500", "50150")
    end

    test "a percent margin is rounded up to the whole rupiah" do
      pulsa =
        product(
          category: "pulsa",
          cost: d("10150"),
          margin_type: "percent",
          margin_value: d("15")
        )

      # 10150 × 1.15 = 11672.5
      assert_price(Services.price_for(pulsa, nil), "11673", "10150")
    end

    test "a bill is the bill plus the admin fee; its cost the bill plus the provider fee" do
      fixed =
        product(
          category: "tagihan",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      assert_price(Services.price_for(fixed, d("245000")), "248000", "246500")

      percent =
        product(
          category: "tagihan",
          cost: d("1500"),
          margin_type: "percent",
          margin_value: d("1")
        )

      assert_price(Services.price_for(percent, d("245000")), "247450", "246500")
    end

    test "a bill of several sheets pays the admin and provider fees per sheet" do
      fixed =
        product(
          category: "tagihan",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      # 735.000 + 3 × 3.000; cost 735.000 + 3 × 1.500
      assert_price(Services.price_for(fixed, d("735000"), 3), "744000", "739500")

      percent =
        product(
          category: "tagihan",
          cost: d("1500"),
          margin_type: "percent",
          margin_value: d("1")
        )

      # 1% of the whole bill, however many sheets
      assert_price(Services.price_for(percent, d("735000"), 3), "742350", "739500")
    end

    test "sheets don't change a fixed-value product" do
      token =
        product(
          category: "token_pln",
          cost: d("50150"),
          margin_type: "amount",
          margin_value: d("2350")
        )

      assert_price(Services.price_for(token, nil, 3), "52500", "50150")
    end

    test "a bill without its amount has no price" do
      bill =
        product(
          category: "tagihan",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      assert Services.price_for(bill, nil) == {:error, :bill_required}
      assert Services.price_for(bill, d("0")) == {:error, :bill_required}
    end
  end

  describe "record/3" do
    setup do
      account = deposit_account_fixture()
      store = assign_account(default_store(), account)
      cashier = user_on_shift_fixture()

      %{account: account, store: store, cashier: cashier, product: service_product_fixture()}
    end

    defp cash(paid, ref \\ "081234567890"),
      do: %{"customer_ref" => ref, "payment_method" => "cash", "amount_paid" => paid}

    test "records a processing transaction in the shift's store, with the price and cost of the moment",
         ctx do
      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, cash("12000"))

      assert tx.status == "processing"
      assert tx.store_id == ctx.store.id
      assert tx.shift_id == Zahlungs.Shifts.current_shift(ctx.cashier).id
      assert tx.user_id == ctx.cashier.id
      assert tx.deposit_account_id == ctx.account.id
      assert Decimal.equal?(tx.price, d("12000"))
      assert Decimal.equal?(tx.cost, d("10150"))
      assert {tx.product_name, tx.category} == {ctx.product.name, "pulsa"}
      assert tx.code =~ ~r/^#{ctx.store.code}-LYN\d{12}[0-9A-F]{4}$/

      {:ok, _} = Services.update_product(ctx.product, %{margin_value: "5000"})
      assert Decimal.equal?(Repo.get!(Services.Transaction, tx.id).price, d("12000"))
    end

    test "cash must cover the price; change is worked out", ctx do
      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, cash("20000"))
      assert Decimal.equal?(tx.amount_paid, d("20000"))
      assert Decimal.equal?(tx.change_due, d("8000"))

      assert Services.record(ctx.cashier, ctx.product.id, cash("10000")) ==
               {:error, :insufficient_payment}

      qris = %{"customer_ref" => "081234567890", "payment_method" => "qris", "amount_paid" => "1"}
      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, qris)
      assert Decimal.equal?(tx.amount_paid, d("12000"))
      assert Decimal.equal?(tx.change_due, d("0"))
    end

    test "tagihan PLN needs the bill", ctx do
      bill =
        service_product_fixture(%{
          category: "tagihan",
          cost: "1500",
          margin_value: "3000"
        })

      assert Services.record(ctx.cashier, bill.id, cash("300000", "530011223344")) ==
               {:error, :bill_required}

      attrs = Map.put(cash("300000", "530011223344"), "bill_amount", "245000")
      assert {:ok, tx} = Services.record(ctx.cashier, bill.id, attrs)
      assert Decimal.equal?(tx.bill_amount, d("245000"))
      assert Decimal.equal?(tx.price, d("248000"))
      assert Decimal.equal?(tx.cost, d("246500"))
    end

    test "the customer number keeps its digits only", ctx do
      assert {:ok, tx} =
               Services.record(ctx.cashier, ctx.product.id, cash("12000", "0812-3456 7890"))

      assert tx.customer_ref == "081234567890"

      assert {:ok, tx} =
               Services.record(ctx.cashier, ctx.product.id, cash("12000", "+62 812.3456.7890"))

      assert tx.customer_ref == "6281234567890"

      for bad <- ["0812abc", "123", ""] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Services.record(ctx.cashier, ctx.product.id, cash("12000", bad))

        assert errors_on(changeset)[:customer_ref], "#{inspect(bad)} was accepted"
      end
    end

    test "refuses without an open shift", ctx do
      assert Services.record(user_fixture(), ctx.product.id, cash("12000")) ==
               {:error, :no_open_shift}
    end

    test "refuses where the store has no active deposit account", ctx do
      bare_store = store_fixture()
      elsewhere = user_on_shift_fixture(%{store_id: bare_store.id})

      assert Services.record(elsewhere, ctx.product.id, cash("12000")) ==
               {:error, :no_deposit_account}

      {:ok, _} = Zahlungs.Deposits.update_account(ctx.account, %{active: false})

      assert Services.record(ctx.cashier, ctx.product.id, cash("12000")) ==
               {:error, :no_deposit_account}
    end

    test "refuses a product no longer for sale", ctx do
      inactive = service_product_fixture(%{active: false})
      deleted = service_product_fixture()
      {:ok, _} = Services.delete_product(deleted)

      for id <- [inactive.id, deleted.id, "#{deleted.id}", -1, "not-an-id"] do
        assert Services.record(ctx.cashier, id, cash("12000")) == {:error, :product_unavailable}
      end
    end

    test "refuses when the price is no longer the one the cashier quoted", ctx do
      quoted = Map.put(cash("20000"), "expected_price", "12000")
      {:ok, _} = Services.update_product(ctx.product, %{margin_value: "2850"})

      assert Services.record(ctx.cashier, ctx.product.id, quoted) == {:error, :price_changed}
      assert Services.list_shift_transactions(Zahlungs.Shifts.current_shift(ctx.cashier)) == []

      requoted = Map.put(cash("20000"), "expected_price", "13000")
      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, requoted)
      assert Decimal.equal?(tx.change_due, d("7000"))
    end

    test "the store comes from the shift, not from the caller", ctx do
      other = store_fixture()
      attrs = Map.put(cash("12000"), "store_id", other.id)

      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, attrs)
      assert tx.store_id == ctx.store.id
    end
  end

  describe "marking the result" do
    setup do
      store = assign_account(default_store(), deposit_account_fixture())
      cashier = user_on_shift_fixture()

      %{store: store, cashier: cashier, product: service_product_fixture()}
    end

    defp status_of(tx), do: Repo.get!(Services.Transaction, tx.id).status

    test "success keeps the token; failure needs a reason", ctx do
      tx = service_fixture(ctx.cashier, ctx.product)
      token = "5821 0344 9917 2268 4410"

      assert {:ok, done} = Services.mark_success(tx, ctx.cashier, token)

      assert {done.status, done.token_sn, done.resolved_by_id} ==
               {"success", token, ctx.cashier.id}

      assert done.resolved_at

      tx = service_fixture(ctx.cashier, ctx.product)
      assert {:error, changeset} = Services.mark_failed(tx, ctx.cashier, "")
      assert errors_on(changeset)[:failure_reason]
      assert status_of(tx) == "processing"

      assert {:ok, failed} = Services.mark_failed(tx, ctx.cashier, "nomor tidak aktif")
      assert {failed.status, failed.failure_reason} == {"failed", "nomor tidak aktif"}

      tx = service_fixture(ctx.cashier, ctx.product)

      assert {:error, changeset} =
               Services.mark_success(tx, ctx.cashier, String.duplicate("1", 65))

      assert errors_on(changeset)[:token_sn]
    end

    test "a token is optional", ctx do
      tx = service_fixture(ctx.cashier, ctx.product)

      assert {:ok, done} = Services.mark_success(tx, ctx.cashier, "")
      assert {done.status, done.token_sn} == {"success", nil}
    end

    test "a result is final", ctx do
      tx = service_fixture(ctx.cashier, ctx.product)
      {:ok, done} = Services.mark_success(tx, ctx.cashier, nil)

      assert Services.mark_success(done, ctx.cashier, nil) == {:error, :not_processing}
      assert Services.mark_failed(done, ctx.cashier, "salah") == {:error, :not_processing}
    end

    test "a stale struct cannot win twice", ctx do
      tx = service_fixture(ctx.cashier, ctx.product)
      other_tab = tx

      assert {:ok, _} = Services.mark_success(tx, ctx.cashier, nil)
      assert Services.mark_failed(other_tab, ctx.cashier, "gagal") == {:error, :not_processing}
      assert status_of(tx) == "success"
    end

    test "only the cashier who recorded it, or an admin, may mark it", ctx do
      tx = service_fixture(ctx.cashier, ctx.product)

      assert Services.mark_success(tx, user_fixture(), nil) == {:error, :forbidden}
      assert status_of(tx) == "processing"

      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
      assert {:ok, _} = Services.mark_failed(tx, admin, "dibatalkan pelanggan")
    end

    test "is fetched only from its own store; listed and counted per shift", ctx do
      first = service_fixture(ctx.cashier, ctx.product)
      second = service_fixture(ctx.cashier, ctx.product)
      {:ok, _} = Services.mark_success(first, ctx.cashier, nil)
      shift = Zahlungs.Shifts.current_shift(ctx.cashier)

      assert Services.get_transaction!(store_scope(), first.id).id == first.id

      assert_raise Ecto.NoResultsError, fn ->
        Services.get_transaction!(store_scope(store_fixture()), first.id)
      end

      assert Enum.map(Services.list_shift_transactions(shift), & &1.id) == [second.id, first.id]
      assert Services.count_processing(shift) == 1
    end
  end

  describe "report/3" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      cashier = user_on_shift_fixture()

      pulsa = service_product_fixture()

      token =
        service_product_fixture(%{category: "token_pln", cost: "50150", margin_value: "2350"})

      for product <- [pulsa, token] do
        tx = service_fixture(cashier, product)
        {:ok, _} = Services.mark_success(tx, cashier, nil)
      end

      failed = service_fixture(cashier, pulsa)
      {:ok, _} = Services.mark_failed(failed, cashier, "gagal")

      # Still processing: not in the report yet.
      service_fixture(cashier, pulsa)

      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
      today = Zahlungs.LocalTime.today()

      %{admin: admin, cashier: cashier, pulsa: pulsa, today: today}
    end

    defp money(value), do: Decimal.new(value)

    test "counts successful services, their value, cost and margin, per category", ctx do
      report = Services.report(store_scope(), ctx.today, ctx.today)

      assert {report.success_count, report.failed_count} == {2, 1}
      assert Decimal.equal?(report.value, money("64500"))
      assert Decimal.equal?(report.cost, money("60300"))
      assert Decimal.equal?(report.margin, money("4200"))

      by = Map.new(report.by_category, &{&1.category, &1})
      assert by["pulsa"].count == 1
      assert Decimal.equal?(by["pulsa"].margin, money("1850"))
      assert by["token_pln"].count == 1
      assert Decimal.equal?(by["token_pln"].value, money("52500"))
    end

    test "a bill is reported under the Tagihan category", ctx do
      bill =
        service_product_fixture(%{name: "Bill 1378", category: "tagihan", cost: "1500"})

      tx = service_fixture(ctx.cashier, bill, %{"bill_amount" => "100000"})
      {:ok, _} = Services.mark_success(tx, ctx.cashier, nil)

      report = Services.report(store_scope(), ctx.today, ctx.today)
      by = Map.new(report.by_category, &{&1.category, &1})
      assert by["tagihan"].count == 1
      assert Services.get_transaction!(scope(ctx.cashier), tx.id).category == "tagihan"
      assert {"tagihan", "Tagihan"} in Services.categories()
    end

    test "one store, all stores of the organization, never another organization", ctx do
      other_store = store_fixture()
      assign_account(other_store, deposit_account_fixture())
      elsewhere = user_on_shift_fixture(%{store_id: other_store.id})
      tx = service_fixture(elsewhere, ctx.pulsa)
      {:ok, _} = Services.mark_success(tx, elsewhere, nil)

      in_org(organization_fixture(), fn ->
        foreign_store = store_fixture()
        assign_account(foreign_store, deposit_account_fixture())
        foreigner = user_on_shift_fixture(%{store_id: foreign_store.id})
        foreign = service_fixture(foreigner, service_product_fixture())
        {:ok, _} = Services.mark_success(foreign, foreigner, nil)
      end)

      assert Services.report(store_scope(), ctx.today, ctx.today).success_count == 2
      assert Services.report(all_stores_scope(ctx.admin), ctx.today, ctx.today).success_count == 3
    end

    test "only the chosen days count", ctx do
      assert Services.report(store_scope(), ~D[2001-01-01], ~D[2001-01-31]).success_count == 0
      assert Services.report(store_scope(), ctx.today, ctx.today).success_count == 2
    end
  end

  describe "products" do
    test "validates the category, the margin and the cost" do
      assert {:error, changeset} =
               Services.create_product(%{name: "X", category: "game", cost: "1"})

      assert errors_on(changeset)[:category]

      assert {:error, changeset} =
               Services.create_product(%{
                 name: "X",
                 category: "pulsa",
                 cost: "10000",
                 margin_value: "-1"
               })

      assert errors_on(changeset)[:margin_value]

      assert {:error, changeset} =
               Services.create_product(%{name: "X", category: "pulsa", cost: "0"})

      assert errors_on(changeset)[:cost]

      assert {:ok, bill} =
               Services.create_product(%{name: "Tagihan PLN", category: "tagihan", cost: "0"})

      assert Zahlungs.Services.Product.bill?(bill)
    end

    test "the old Tagihan PLN category is gone; a bill may ask for months" do
      assert {:error, changeset} =
               Services.create_product(%{name: "X", category: "tagihan" <> "_pln", cost: "0"})

      assert errors_on(changeset)[:category]

      assert {:ok, plain} =
               Services.create_product(%{name: "BPJS", category: "tagihan", cost: "0"})

      refute plain.ask_months

      assert {:ok, asking} =
               Services.create_product(%{
                 name: "BPJS 2",
                 category: "tagihan",
                 cost: "0",
                 ask_months: true
               })

      assert asking.ask_months
      assert Services.get_product!(asking.id).ask_months
    end

    test "keeps the shop's extra fee on api bills, never negative" do
      assert {:error, changeset} =
               Services.create_product(%{
                 name: "Tagihan PLN",
                 category: "tagihan",
                 cost: "0",
                 api_extra_fee: "-1"
               })

      assert errors_on(changeset)[:api_extra_fee]

      assert {:ok, bill} =
               Services.create_product(%{
                 name: "Tagihan PLN",
                 category: "tagihan",
                 cost: "0",
                 api_extra_fee: "2500"
               })

      assert Decimal.equal?(bill.api_extra_fee, d("2500"))
    end

    test "keeps the vendor's product code, up to 60 characters" do
      product = service_product_fixture(%{provider_code: "PLNPASCA"})
      assert product.provider_code == "PLNPASCA"

      assert {:error, changeset} =
               Services.update_product(product, %{provider_code: String.duplicate("X", 61)})

      assert errors_on(changeset)[:provider_code]
    end

    test "a deleted product is no longer listed or found" do
      product = service_product_fixture()
      assert product.id in Enum.map(Services.list_products(), & &1.id)

      {:ok, _} = Services.delete_product(product)

      refute product.id in Enum.map(Services.list_products(), & &1.id)
      assert_raise Ecto.NoResultsError, fn -> Services.get_product!(product.id) end
    end

    test "lists by category and active flag" do
      pulsa = service_product_fixture(%{category: "pulsa"})
      token = service_product_fixture(%{category: "token_pln", active: false})

      assert pulsa.id in Enum.map(Services.list_products(category: "pulsa"), & &1.id)
      refute token.id in Enum.map(Services.list_products(category: "pulsa"), & &1.id)
      refute token.id in Enum.map(Services.list_products(active: true), & &1.id)
    end

    test "another organization's products are invisible" do
      other = in_org(organization_fixture(), fn -> service_product_fixture() end)

      refute other.id in Enum.map(Services.list_products(), & &1.id)
      assert_raise Ecto.NoResultsError, fn -> Services.get_product!(other.id) end
    end
  end
end
