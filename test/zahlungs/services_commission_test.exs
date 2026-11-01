defmodule Zahlungs.ServicesCommissionTest do
  @moduledoc """
  Cashier commission on service transactions: the percent per category (the
  admin's), copied onto a service when a cashier records it, and the amount
  worked out from the final status, price and cost.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Transaction

  defp admin do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp percent(category), do: Services.commission_percent(category)

  describe "rates" do
    setup do
      %{admin: admin()}
    end

    test "a category without a rate is 0%" do
      rates = Services.commission_rates()

      assert Enum.map(rates, & &1.category) == Enum.map(Services.categories(), &elem(&1, 0))
      assert Enum.all?(rates, &Decimal.equal?(&1.percent, 0))
      assert Decimal.equal?(percent("pulsa"), 0)
    end

    test "an admin saves every category at once; blank is 0", %{admin: admin} do
      assert {:ok, _} =
               Services.save_commission_rates(admin, %{
                 "pulsa" => "10",
                 "tagihan" => "12.5",
                 "token_pln" => ""
               })

      assert Decimal.equal?(percent("pulsa"), "10")
      assert Decimal.equal?(percent("tagihan"), "12.5")
      assert Decimal.equal?(percent("token_pln"), 0)

      # Saved again: updated, not duplicated.
      assert {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "20"})
      assert Decimal.equal?(percent("pulsa"), "20")
      assert length(Services.commission_rates()) == length(Services.categories())
    end

    test "one wrong value saves nothing", %{admin: admin} do
      for bad <- ["-1", "101", "abc", "1.234", "12,5"] do
        assert {:error, %{"paket_data" => message}} =
                 Services.save_commission_rates(admin, %{"pulsa" => "10", "paket_data" => bad})

        assert is_binary(message)
        assert Decimal.equal?(percent("pulsa"), 0)
      end
    end

    test "a cashier can't save" do
      assert Services.save_commission_rates(user_fixture(), %{"pulsa" => "10"}) ==
               {:error, :unauthorized}

      assert Decimal.equal?(percent("pulsa"), 0)
    end

    test "another organization's rates are not ours" do
      in_org(organization_fixture(), fn ->
        {:ok, _} = Services.save_commission_rates(admin(), %{"pulsa" => "50"})
        assert Decimal.equal?(percent("pulsa"), "50")
      end)

      assert Decimal.equal?(percent("pulsa"), 0)
    end
  end

  describe "recording" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      admin = admin()
      {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10", "tagihan" => "12.5"})

      %{admin: admin, cashier: user_on_shift_fixture(), pulsa: service_product_fixture()}
    end

    test "a cashier's service carries the category's percent", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      assert Decimal.equal?(tx.commission_percent, "10")

      token = service_product_fixture(%{category: "token_pln"})
      assert Decimal.equal?(service_fixture(ctx.cashier, token).commission_percent, 0)
    end

    test "an admin's service carries none" do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")
      tx = service_fixture(admin, service_product_fixture())
      assert Decimal.equal?(tx.commission_percent, 0)
    end

    test "the role is read from the database, not the struct", ctx do
      {:ok, _} = Zahlungs.Accounts.set_user_role(ctx.cashier, "admin")

      # ctx.cashier still says "cashier".
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      assert Decimal.equal?(tx.commission_percent, 0)
    end

    test "the percent can't come from the caller", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa, %{"commission_percent" => "99"})
      assert Decimal.equal?(tx.commission_percent, "10")
    end

    test "a later change of percent leaves recorded services alone", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      {:ok, _} = Services.save_commission_rates(ctx.admin, %{"pulsa" => "50"})

      assert Decimal.equal?(Repo.get!(Transaction, tx.id).commission_percent, "10")
    end
  end

  describe "commission/1" do
    defp tx(status, price, cost, percent) do
      %Transaction{
        status: status,
        price: Decimal.new(price),
        cost: Decimal.new(cost),
        commission_percent: Decimal.new(percent)
      }
    end

    test "a percent of a successful service's margin, rounded down to the rupiah" do
      assert Decimal.equal?(Services.commission(tx("success", "12000", "10150", "10")), 185)
      assert Decimal.equal?(Services.commission(tx("success", "12000", "10001", "12.5")), 249)
    end

    test "nothing for a service that isn't successful, or sold at a loss" do
      assert Decimal.equal?(Services.commission(tx("processing", "12000", "10150", "10")), 0)
      assert Decimal.equal?(Services.commission(tx("failed", "12000", "10150", "10")), 0)
      assert Decimal.equal?(Services.commission(tx("success", "12000", "12500", "10")), 0)
    end
  end
end
