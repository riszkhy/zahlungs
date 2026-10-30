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

  describe "repayments" do
    setup do
      user = user_on_shift_fixture()
      %{user: user, shift: Shifts.current_shift(user), customer: customer_fixture()}
    end

    defp pay(user, customer, amount, method \\ "cash") do
      Customers.receive_payment(user, customer.id, %{
        "amount" => amount,
        "payment_method" => method
      })
    end

    defp admin_on_shift do
      admin = admin()
      shift_fixture(admin)
      admin
    end

    test "partial then full repayment", ctx do
      credit!(ctx.user, ctx.customer, "50000")

      assert {:ok, payment} = pay(ctx.user, ctx.customer, "20000")
      assert {payment.store_id, payment.shift_id} == {ctx.shift.store_id, ctx.shift.id}
      assert Decimal.equal?(Customers.balance(ctx.customer), d("30000"))

      assert {:ok, _} = pay(ctx.user, ctx.customer, "30000", "qris")
      assert Decimal.equal?(Customers.balance(ctx.customer), d("0"))
      assert pay(ctx.user, ctx.customer, "1") == {:error, :over_balance}
    end

    test "a repayment needs an open shift and a known customer", ctx do
      credit!(ctx.user, ctx.customer, "50000")

      assert pay(user_fixture(), ctx.customer, "1000") == {:error, :no_open_shift}

      assert Customers.receive_payment(ctx.user, -1, %{"amount" => "1"}) ==
               {:error, :not_found}

      assert {:error, %Ecto.Changeset{}} = pay(ctx.user, ctx.customer, "1000", "bitcoin")
    end

    test "cash counts in the receiving shift's drawer, non-cash doesn't", ctx do
      credit!(ctx.user, ctx.customer, "50000")
      other = user_on_shift_fixture(%{store_id: store_fixture().id})
      their_shift = Shifts.current_shift(other)

      {:ok, payment} = pay(other, ctx.customer, "20000")
      {:ok, _} = pay(other, ctx.customer, "5000", "transfer")

      assert payment.store_id == their_shift.store_id
      assert Decimal.equal?(Shifts.expected_cash(their_shift), d("20000"))

      summary = Shifts.shift_summary(their_shift)
      assert Decimal.equal?(summary.payments_cash, d("20000"))
      assert Decimal.equal?(summary.payments_noncash, d("5000"))
      assert Decimal.equal?(summary.expected_cash, d("20000"))
      assert Decimal.equal?(Shifts.expected_cash(ctx.shift), d("0"))
    end

    test "repayments settle the oldest note first", ctx do
      a = credit!(ctx.user, ctx.customer, "30000")
      b = credit!(ctx.user, ctx.customer, "20000")
      {:ok, _} = pay(ctx.user, ctx.customer, "40000")

      assert [%{sale: %{id: b_id}, remaining: remaining}] = Customers.open_notes(ctx.customer)
      assert b_id == b.id
      assert Decimal.equal?(remaining, d("10000"))

      assert [sale_a, sale_b, payment] = Customers.ledger(ctx.customer)
      assert {sale_a.kind, sale_b.kind, payment.kind} == {:sale, :sale, :payment}
      assert {sale_a.status, sale_b.status} == {:paid, :open}

      assert Enum.map(payment.settles, &{&1.code, Decimal.to_integer(&1.remaining)}) ==
               [{a.code, 0}, {b.code, 10000}]

      assert Enum.map([sale_a, sale_b, payment], &Decimal.to_integer(&1.balance)) ==
               [30000, 50000, 10000]
    end

    test "overdue uses the store's local date", ctx do
      sale = credit!(ctx.user, ctx.customer, "10000")
      today = LocalTime.today(default_store())

      Zahlungs.Repo.update_all(
        from(s in Zahlungs.Sales.Sale, where: s.id == ^sale.id),
        set: [due_date: today]
      )

      assert [%{overdue?: false}] = Customers.open_notes(ctx.customer)

      Zahlungs.Repo.update_all(
        from(s in Zahlungs.Sales.Sale, where: s.id == ^sale.id),
        set: [due_date: Date.add(today, -1)]
      )

      assert [%{overdue?: true}] = Customers.open_notes(ctx.customer)
      assert [%{overdue?: true}] = Customers.ledger(ctx.customer)
    end

    test "only an admin cancels a repayment, while its shift is open", ctx do
      credit!(ctx.user, ctx.customer, "50000")
      {:ok, payment} = pay(ctx.user, ctx.customer, "20000")
      admin = admin()

      assert Customers.cancel_payment(ctx.user, payment.id, "salah input") ==
               {:error, :unauthorized}

      assert {:error, %Ecto.Changeset{}} = Customers.cancel_payment(admin, payment.id, " ")

      assert {:ok, cancelled} = Customers.cancel_payment(admin, payment.id, "salah input")
      assert cancelled.cancelled_by_id == admin.id
      assert Decimal.equal?(Customers.balance(ctx.customer), d("50000"))
      assert Decimal.equal?(Shifts.expected_cash(ctx.shift), d("0"))

      assert Customers.cancel_payment(admin, payment.id, "lagi") ==
               {:error, :already_cancelled}

      assert [_sale, %{kind: :payment, cancelled?: true, balance: balance}] =
               Customers.ledger(ctx.customer)

      assert Decimal.equal?(balance, d("50000"))

      {:ok, later} = pay(ctx.user, ctx.customer, "1000")
      {:ok, _} = Shifts.close_shift(ctx.shift, "1000")

      assert Customers.cancel_payment(admin, later.id, "telat") == {:error, :shift_closed}
    end

    test "returning a note paid in part leaves an overpayment", ctx do
      sale = credit!(ctx.user, ctx.customer, "50000")
      {:ok, _} = pay(ctx.user, ctx.customer, "20000")

      {:ok, _} = Sales.return_sale(sale, admin())
      assert Decimal.equal?(Customers.balance(ctx.customer), d("-20000"))
      assert [%{status: :cancelled} | _] = Customers.ledger(ctx.customer)

      credit!(ctx.user, ctx.customer, "30000")
      assert Decimal.equal?(Customers.balance(ctx.customer), d("10000"))
    end

    test "an admin hands an overpayment back in cash", ctx do
      sale = credit!(ctx.user, ctx.customer, "50000")
      {:ok, _} = pay(ctx.user, ctx.customer, "20000")
      {:ok, _} = Sales.return_sale(sale, admin())
      admin = admin_on_shift()

      assert Customers.refund_overpayment(ctx.user, ctx.customer.id, "20000") ==
               {:error, :unauthorized}

      assert Customers.refund_overpayment(admin(), ctx.customer.id, "20000") ==
               {:error, :no_open_shift}

      assert Customers.refund_overpayment(admin, ctx.customer.id, "25000") ==
               {:error, :over_overpayment}

      assert {:ok, movement} = Customers.refund_overpayment(admin, ctx.customer.id, "20000")
      assert {movement.category, movement.customer_id} == {"customer_refund", ctx.customer.id}
      assert Decimal.equal?(Customers.balance(ctx.customer), d("0"))

      admin_shift = Shifts.current_shift(admin)
      assert Decimal.equal?(Shifts.expected_cash(admin_shift), d("-20000"))
      assert [_, _, %{kind: :refund}] = Customers.ledger(ctx.customer)
    end

    test "a credit sale returned after its shift closed refunds the down payment only", ctx do
      sale = credit!(ctx.user, ctx.customer, "60000", "10000")
      {:ok, _} = Shifts.close_shift(ctx.shift, "10000")
      admin = admin_on_shift()

      {:ok, _} = Sales.return_sale(sale, admin)

      assert Decimal.equal?(Shifts.expected_cash(Shifts.current_shift(admin)), d("-10000"))
    end
  end

  describe "reports" do
    setup do
      user = user_on_shift_fixture()
      %{user: user, customer: customer_fixture()}
    end

    test "receivables: who owes what, and what is overdue", ctx do
      paid_up = customer_fixture()
      sale = credit!(ctx.user, ctx.customer, "30000")
      credit!(ctx.user, ctx.customer, "20000")
      credit!(ctx.user, paid_up, "5000")

      {:ok, _} =
        Customers.receive_payment(ctx.user, paid_up.id, %{
          "amount" => "5000",
          "payment_method" => "cash"
        })

      Zahlungs.Repo.update_all(
        from(s in Zahlungs.Sales.Sale, where: s.id == ^sale.id),
        set: [due_date: Date.add(LocalTime.today(default_store()), -3)]
      )

      report = Customers.receivables_report()
      row = Enum.find(report.rows, &(&1.customer.id == ctx.customer.id))

      assert Decimal.equal?(row.balance, d("50000"))
      assert Decimal.equal?(row.overdue, d("30000"))
      assert row.oldest_open.id == sale.id
      refute Enum.any?(report.rows, &(&1.customer.id == paid_up.id))
      assert Decimal.compare(report.total, d("50000")) in [:gt, :eq]

      overdue = Customers.receivables_report(overdue_only: true)
      assert Enum.any?(overdue.rows, &(&1.customer.id == ctx.customer.id))
    end

    test "repayments by method and store", ctx do
      credit!(ctx.user, ctx.customer, "50000")

      for {amount, method} <- [{"10000", "cash"}, {"5000", "qris"}, {"2000", "cash"}] do
        {:ok, _} =
          Customers.receive_payment(ctx.user, ctx.customer.id, %{
            "amount" => amount,
            "payment_method" => method
          })
      end

      today = LocalTime.today(default_store())
      report = Customers.payments_report(store_scope(), today, today)

      assert Decimal.equal?(report.total, d("17000"))
      assert {"cash", cash} = List.keyfind(report.by_method, "cash", 0)
      assert Decimal.equal?(cash, d("12000"))
      assert [{name, amount}] = report.by_store
      assert name == default_store().name
      assert Decimal.equal?(amount, d("17000"))
    end
  end
end
