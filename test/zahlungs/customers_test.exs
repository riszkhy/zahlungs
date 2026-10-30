defmodule Zahlungs.CustomersTest do
  @moduledoc """
  Customers who may buy on credit: one list per organization, a credit limit
  only an admin sets, and a balance always computed from credit sales and
  repayments.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CustomersFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, Customers}

  defp d(value), do: Decimal.new(value)

  defp admin do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  describe "customers" do
    test "a cashier's new customer gets no credit" do
      assert {:ok, customer} =
               Customers.create_customer(user_fixture(), %{
                 "name" => unique_name("Bu Ani"),
                 "phone" => "0812",
                 "credit_limit" => "500000"
               })

      assert Decimal.equal?(customer.credit_limit, 0)
      assert customer.active
    end

    test "an admin sets the limit" do
      assert {:ok, customer} =
               Customers.create_customer(admin(), %{
                 "name" => unique_name("Pak Budi"),
                 "credit_limit" => "500000"
               })

      assert Decimal.equal?(customer.credit_limit, d("500000"))
    end

    test "names are unique per organization, ignoring case" do
      name = unique_name("Bu Ani")
      user = user_fixture()
      {:ok, _} = Customers.create_customer(user, %{"name" => name})

      assert {:error, changeset} =
               Customers.create_customer(user, %{"name" => String.downcase(name)})

      assert errors_on(changeset)[:name]

      other = organization_fixture()
      theirs = %Accounts.User{role: "cashier", organization_id: other.id}

      in_org(other, fn ->
        assert {:ok, _} = Customers.create_customer(theirs, %{"name" => name})
      end)
    end

    test "only an admin updates or deactivates" do
      customer = customer_fixture()
      cashier = user_fixture()

      assert Customers.update_customer(cashier, customer, %{"credit_limit" => "9"}) ==
               {:error, :unauthorized}

      assert Customers.set_active(cashier, customer, false) == {:error, :unauthorized}

      assert {:ok, updated} =
               Customers.update_customer(admin(), customer, %{"credit_limit" => "250000"})

      assert Decimal.equal?(updated.credit_limit, d("250000"))
      assert {:ok, %{active: false}} = Customers.set_active(admin(), customer, false)
    end

    test "list searches name and phone, active only" do
      tag = unique_name("Cari")
      a = customer_fixture(%{name: "#{tag} Ani", phone: "0811111"})
      b = customer_fixture(%{name: "#{tag} Budi", phone: "0822222", active: false})

      assert [a.id, b.id] == Enum.map(Customers.list_customers(q: tag), & &1.id)
      assert [a.id] == Enum.map(Customers.list_customers(q: tag, active_only: true), & &1.id)

      assert b.id in Enum.map(Customers.list_customers(q: "0822222"), & &1.id)
    end

    test "another organization's customer is not found" do
      customer = customer_fixture()

      in_org(organization_fixture(), fn ->
        assert_raise Ecto.NoResultsError, fn -> Customers.get_customer!(customer.id) end
      end)
    end
  end
end
