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
          category: "tagihan_pln",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      assert_price(Services.price_for(fixed, d("245000")), "248000", "246500")

      percent =
        product(
          category: "tagihan_pln",
          cost: d("1500"),
          margin_type: "percent",
          margin_value: d("1")
        )

      assert_price(Services.price_for(percent, d("245000")), "247450", "246500")
    end

    test "a bill without its amount has no price" do
      bill =
        product(
          category: "tagihan_pln",
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
          category: "tagihan_pln",
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

    test "the store comes from the shift, not from the caller", ctx do
      other = store_fixture()
      attrs = Map.put(cash("12000"), "store_id", other.id)

      assert {:ok, tx} = Services.record(ctx.cashier, ctx.product.id, attrs)
      assert tx.store_id == ctx.store.id
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

      assert {:ok, _bill} =
               Services.create_product(%{name: "Tagihan PLN", category: "tagihan_pln", cost: "0"})
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
