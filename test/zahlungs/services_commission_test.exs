defmodule Zahlungs.ServicesCommissionTest do
  @moduledoc """
  Cashier commission on service transactions: the percent per category (the
  admin's), copied onto a service when a cashier records it, and the amount
  worked out from the final status, price and cost.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Services

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
end
