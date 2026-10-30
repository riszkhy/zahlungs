defmodule Zahlungs.CustomersTest do
  @moduledoc """
  Customers who may buy on credit: one list per organization, a credit limit
  only an admin sets, and a balance always computed from credit sales and
  repayments.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.CustomersFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, Customers, LocalTime, Sales, Shifts}

  defp d(value), do: Decimal.new(value)

  defp admin do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  defp credit(user, customer, total, down_payment \\ "", extra \\ %{}) do
    product = product_fixture(price: Decimal.new(total), stock: 100)

    Sales.create_sale(
      user,
      [%{product_id: product.id, quantity: 1}],
      Map.merge(
        %{
          payment_method: "credit",
          customer_id: customer && customer.id,
          amount_paid: down_payment,
          due_date: Date.add(LocalTime.today(default_store()), 30)
        },
        extra
      )
    )
  end

  defp credit!(user, customer, total, down_payment \\ "") do
    {:ok, sale} = credit(user, customer, total, down_payment)
    sale
  end

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

  describe "credit sales" do
    setup do
      %{user: user_on_shift_fixture()}
    end

    test "balance and limit", %{user: user} do
      customer = customer_fixture(%{credit_limit: "100000"})
      sale = credit!(user, customer, "60000", "10000")

      assert sale.payment_method == "credit"
      assert sale.customer_id == customer.id
      assert Decimal.equal?(sale.amount_paid, d("10000"))
      assert Decimal.equal?(sale.change_due, d("0"))
      assert Decimal.equal?(Customers.balance(customer), d("50000"))
      assert Decimal.equal?(Customers.available_credit(customer), d("50000"))
    end

    test "a credit sale at exactly the limit passes, one rupiah over fails", %{user: user} do
      customer = customer_fixture(%{credit_limit: "50000"})
      assert {:ok, _} = credit(user, customer, "50000")

      product = product_fixture(price: Decimal.new("1"), stock: 5)

      assert Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
               payment_method: "credit",
               customer_id: customer.id,
               due_date: Date.add(LocalTime.today(default_store()), 1)
             }) == {:error, :over_credit_limit}

      assert stock_of(product) == 5
    end

    test "limit 0 or an inactive customer is refused", %{user: user} do
      assert credit(user, customer_fixture(%{credit_limit: "0"}), "1000") ==
               {:error, :over_credit_limit}

      assert credit(user, customer_fixture(%{active: false}), "1000") ==
               {:error, :customer_inactive}
    end

    test "a stale customer struct doesn't help", %{user: user} do
      customer = customer_fixture(%{credit_limit: "50000"})
      stale = Customers.get_customer!(customer.id)
      credit!(user, customer, "40000")

      assert credit(user, stale, "20000") == {:error, :over_credit_limit}
    end

    test "down payment rules", %{user: user} do
      customer = customer_fixture()

      assert {:ok, sale} = credit(user, customer, "5000", "")
      assert Decimal.equal?(sale.amount_paid, d("0"))
      assert credit(user, customer, "5000", "5000") == {:error, :down_payment_too_high}
      assert credit(user, nil, "5000") == {:error, :customer_required}
    end

    test "a due date in the past is refused", %{user: user} do
      customer = customer_fixture()
      today = LocalTime.today(default_store())

      assert credit(user, customer, "5000", "", %{due_date: Date.add(today, -1)}) ==
               {:error, :invalid_due_date}

      assert credit(user, customer, "5000", "", %{due_date: "bukan tanggal"}) ==
               {:error, :invalid_due_date}

      assert {:ok, sale} = credit(user, customer, "5000", "", %{due_date: Date.to_iso8601(today)})
      assert sale.due_date == today
    end

    test "another organization's customer can't be sold to", %{user: user} do
      theirs =
        in_org(organization_fixture(), fn ->
          %Zahlungs.Customers.Customer{}
          |> Zahlungs.Customers.Customer.admin_changeset(%{name: "Asing", credit_limit: "100000"})
          |> Zahlungs.Repo.insert!()
        end)

      assert credit(user, theirs, "1000") == {:error, :not_found}
    end

    test "a cash sale ignores customer and due date", %{user: user} do
      product = product_fixture(price: Decimal.new("1000"), stock: 5)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
          amount_paid: "1000",
          customer_id: customer_fixture().id,
          due_date: "2030-01-01"
        })

      assert {sale.customer_id, sale.due_date} == {nil, nil}
    end

    test "the down payment counts in the drawer, the rest doesn't", %{user: user} do
      credit!(user, customer_fixture(), "60000", "10000")
      shift = Shifts.current_shift(user)

      assert Decimal.equal?(Shifts.expected_cash(shift), d("10000"))

      summary = Shifts.shift_summary(shift)
      assert Decimal.equal?(summary.credit_total, d("60000"))
      assert Decimal.equal?(summary.credit_down_payment, d("10000"))
      assert Decimal.equal?(summary.noncash_total, d("0"))
      assert Decimal.equal?(summary.expected_cash, d("10000"))
    end

    test "credit sales count in the sales report", %{user: user} do
      sale = credit!(user, customer_fixture(), "60000", "10000")
      today = LocalTime.today(default_store())
      report = Sales.sales_report(store_scope(), today, today)

      assert Decimal.equal?(report.credit_total, sale.total)
      assert Decimal.equal?(report.revenue, d("60000"))
    end
  end
end
