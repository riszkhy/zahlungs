defmodule Zahlungs.ShiftsTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Shifts, Sales}

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures

  test "open_shift/2 opens a shift and current_shift/1 finds it" do
    user = user_fixture()
    assert is_nil(Shifts.current_shift(user))

    assert {:ok, shift} = Shifts.open_shift(scope(user), "100000")
    assert shift.status == "open"
    assert Decimal.equal?(shift.opening_cash, Decimal.new("100000"))
    assert Shifts.current_shift(user).id == shift.id
  end

  test "cannot open a second shift while one is open" do
    user = user_fixture()
    {:ok, _} = Shifts.open_shift(scope(user), 100_000)
    assert {:error, :already_open} = Shifts.open_shift(scope(user), 50_000)
  end

  test "close_shift/3 computes expected cash and variance" do
    user = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)
    {:ok, shift} = Shifts.open_shift(scope(user), "100000")

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
        amount_paid: "2000"
      })

    # expected = opening 100000 + cash sales 2000 = 102000; counted 101500 => -500
    assert {:ok, closed} = Shifts.close_shift(shift, "101500", "kurang 500")
    assert closed.status == "closed"
    assert Decimal.equal?(closed.expected_cash, Decimal.new("102000"))
    assert Decimal.equal?(closed.variance, Decimal.new("-500"))
    assert is_nil(Shifts.current_shift(user))
  end

  test "cannot close an already-closed shift" do
    user = user_fixture()
    {:ok, shift} = Shifts.open_shift(scope(user), 0)
    {:ok, closed} = Shifts.close_shift(shift, 0)
    assert {:error, :not_open} = Shifts.close_shift(closed, 0)
  end

  test "a stale `open` struct cannot close the shift again or add cash movements" do
    user = user_fixture()
    {:ok, shift} = Shifts.open_shift(scope(user), 0)
    {:ok, closed} = Shifts.close_shift(shift, "500")

    # `shift` still says "open", as it would in a cashier screen left open elsewhere.
    assert {:error, :not_open} = Shifts.close_shift(shift, "999")

    assert {:error, :not_open} =
             Shifts.add_cash_movement(shift, %{"category" => "expense", "amount" => "100"})

    assert Decimal.equal?(
             Shifts.get_shift!(store_scope(), shift.id).counted_cash,
             closed.counted_cash
           )

    assert Shifts.list_cash_movements(shift) == []
  end

  test "a user can open a new shift after closing the previous one" do
    user = user_fixture()
    {:ok, first} = Shifts.open_shift(scope(user), 0)
    {:ok, _} = Shifts.close_shift(first, 0)

    assert {:ok, second} = Shifts.open_shift(scope(user), 0)
    assert Shifts.current_shift(user).id == second.id
  end

  test "open_shift/2 returns the changeset for an invalid opening cash" do
    assert {:error, %Ecto.Changeset{}} = Shifts.open_shift(scope(user_fixture()), "-1")
  end

  test "expected_cash and summary count only cash sales" do
    user = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)
    {:ok, shift} = Shifts.open_shift(scope(user), "100000")

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        amount_paid: "1000",
        payment_method: "cash"
      })

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
        payment_method: "qris"
      })

    # cash 1000 counts toward the drawer; qris 2000 does not
    assert Decimal.equal?(Shifts.expected_cash(shift), Decimal.new("101000"))

    summary = Shifts.shift_summary(shift)
    assert summary.transactions == 2
    assert Decimal.equal?(summary.cash_total, Decimal.new("1000"))
    assert Decimal.equal?(summary.noncash_total, Decimal.new("2000"))
    assert Decimal.equal?(summary.sales_total, Decimal.new("3000"))
    assert Decimal.equal?(summary.expected_cash, Decimal.new("101000"))
  end

  test "cash movements adjust expected cash (in adds, out subtracts)" do
    user = user_fixture()
    {:ok, shift} = Shifts.open_shift(scope(user), "100000")

    {:ok, _} = Shifts.add_cash_movement(shift, %{"category" => "cash_in", "amount" => "20000"})
    {:ok, _} = Shifts.add_cash_movement(shift, %{"category" => "expense", "amount" => "5000"})

    # 100000 + 20000 - 5000 = 115000
    assert Decimal.equal?(Shifts.expected_cash(shift), Decimal.new("115000"))

    summary = Shifts.shift_summary(shift)
    assert Decimal.equal?(summary.cash_in, Decimal.new("20000"))
    assert Decimal.equal?(summary.cash_out, Decimal.new("5000"))
    assert Decimal.equal?(summary.expected_cash, Decimal.new("115000"))
  end

  test "consignment payment requires a supplier and cannot be recorded on a closed shift" do
    user = user_fixture()
    supplier = supplier_fixture()
    {:ok, shift} = Shifts.open_shift(scope(user), 0)

    assert {:error, changeset} =
             Shifts.add_cash_movement(shift, %{
               "category" => "consignment_payment",
               "amount" => "1000"
             })

    assert %{supplier_id: [_ | _]} = errors_on(changeset)

    assert {:ok, _} =
             Shifts.add_cash_movement(shift, %{
               "category" => "consignment_payment",
               "amount" => "1000",
               "supplier_id" => supplier.id
             })

    {:ok, closed} = Shifts.close_shift(shift, 0)

    assert {:error, :not_open} =
             Shifts.add_cash_movement(closed, %{"category" => "expense", "amount" => "1"})
  end

  test "consignment_payments_by_supplier/2 sums payments per supplier in range" do
    user = user_fixture()
    supplier = supplier_fixture()
    {:ok, shift} = Shifts.open_shift(scope(user), 0)

    {:ok, _} =
      Shifts.add_cash_movement(shift, %{
        "category" => "consignment_payment",
        "amount" => "3000",
        "supplier_id" => supplier.id
      })

    {:ok, _} =
      Shifts.add_cash_movement(shift, %{
        "category" => "consignment_payment",
        "amount" => "2000",
        "supplier_id" => supplier.id
      })

    today = Zahlungs.LocalTime.today()
    paid = Shifts.consignment_payments_by_supplier(store_scope(), today, today)
    assert Decimal.equal?(Map.fetch!(paid, supplier.id), Decimal.new("5000"))
  end

  test "list_shifts/1 can filter by user, and shift_sales/1 lists a shift's sales" do
    user = user_fixture()
    other = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 5)
    {:ok, shift} = Shifts.open_shift(scope(user), 0)
    {:ok, _other_shift} = Shifts.open_shift(scope(other), 0)

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        amount_paid: "1000"
      })

    mine = Shifts.list_shifts(store_scope(), user_id: user.id)
    assert Enum.map(mine, & &1.id) == [shift.id]

    assert [sale] = Shifts.shift_sales(shift)
    assert sale.shift_id == shift.id
  end

  describe "returning or voiding a sale" do
    # A cashier's shift (opening cash 100000) with one sale of 2000.
    defp shift_with_sale(payment) do
      cashier = user_fixture()
      shift = shift_fixture(cashier, "100000")
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} = Sales.create_sale(cashier, [%{product_id: product.id, quantity: 2}], payment)
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

      %{cashier: cashier, shift: shift, sale: sale, admin: admin}
    end

    defp assert_cash(shift, amount),
      do: assert(Decimal.equal?(Shifts.expected_cash(shift), Decimal.new(amount)))

    test "while the shift is open: it stops counting and no cash movement is added" do
      %{shift: shift, sale: sale, admin: admin} = shift_with_sale(%{amount_paid: "2000"})
      admin_shift = shift_fixture(admin, "50000")
      assert_cash(shift, "102000")

      assert {:ok, returned} = Sales.return_sale(sale, admin)

      refute returned.adjusted_after_shift_close
      assert_cash(shift, "100000")
      assert Shifts.list_cash_movements(admin_shift) == []
    end

    test "after the shift is closed: its figures stay, the refund leaves the refunder's drawer" do
      %{shift: shift, sale: sale, admin: admin} = shift_with_sale(%{amount_paid: "2000"})
      {:ok, closed} = Shifts.close_shift(shift, "102000")
      admin_shift = shift_fixture(admin, "50000")

      assert {:ok, returned} = Sales.return_sale(sale, admin)
      assert returned.adjusted_after_shift_close

      # The closed shift still shows what was reconciled at closing.
      assert_cash(closed, "102000")
      assert %{transactions: 1} = Shifts.shift_summary(closed)
      assert Decimal.equal?(Shifts.get_shift!(store_scope(), shift.id).variance, Decimal.new("0"))

      assert [%{category: "refund", direction: "out"} = refund] =
               Shifts.list_cash_movements(admin_shift)

      assert Decimal.equal?(refund.amount, Decimal.new("2000"))
      assert refund.note =~ sale.code
      assert_cash(admin_shift, "48000")
    end

    test "after close, without an open shift the return still goes through" do
      %{shift: shift, sale: sale, admin: admin} = shift_with_sale(%{amount_paid: "2000"})
      {:ok, closed} = Shifts.close_shift(shift, "102000")

      assert {:ok, %{status: "returned"}} = Sales.return_sale(sale, admin)
      assert_cash(closed, "102000")
    end

    test "after close, a non-cash sale is never refunded from a drawer" do
      %{shift: shift, sale: sale, admin: admin} = shift_with_sale(%{payment_method: "qris"})
      {:ok, _closed} = Shifts.close_shift(shift, "100000")
      admin_shift = shift_fixture(admin, "50000")

      assert {:ok, _} = Sales.return_sale(sale, admin)
      assert Shifts.list_cash_movements(admin_shift) == []
      assert_cash(admin_shift, "50000")
    end

    test "after close, an admin's void keeps the closed shift's figures and moves no cash" do
      %{shift: shift, sale: sale, admin: admin} = shift_with_sale(%{amount_paid: "2000"})
      {:ok, closed} = Shifts.close_shift(shift, "102000")
      admin_shift = shift_fixture(admin, "50000")

      assert {:ok, voided} = Sales.void_sale(sale, admin, "salah input")
      assert voided.adjusted_after_shift_close

      assert_cash(closed, "102000")
      assert Shifts.list_cash_movements(admin_shift) == []
    end
  end

  describe "services in the drawer" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      cashier = user_fixture()
      %{cashier: cashier, shift: shift_fixture(cashier, "50000")}
    end

    defp priced(cost, margin),
      do: service_product_fixture(%{cost: cost, margin_type: "amount", margin_value: margin})

    defp money(value), do: Decimal.new(value)

    test "processing and successful cash services count; failed and non-cash ones do not", ctx do
      done = service_fixture(ctx.cashier, priced("10150", "1850"))
      {:ok, _} = Zahlungs.Services.mark_success(done, ctx.cashier, nil)

      _processing = service_fixture(ctx.cashier, priced("50150", "2350"))

      failed = service_fixture(ctx.cashier, priced("25000", "1500"))
      {:ok, _} = Zahlungs.Services.mark_failed(failed, ctx.cashier, "gagal di penyedia")

      qris = service_fixture(ctx.cashier, priced("10000", "1800"), %{"payment_method" => "qris"})
      {:ok, _} = Zahlungs.Services.mark_success(qris, ctx.cashier, nil)

      # 50.000 float + 12.000 (done) + 52.500 (processing)
      assert Decimal.equal?(Shifts.expected_cash(ctx.shift), money("114500"))

      summary = Shifts.shift_summary(ctx.shift)
      assert summary.service_count == 3
      assert Decimal.equal?(summary.service_total, money("76300"))
      assert Decimal.equal?(summary.service_cash_total, money("64500"))
      assert Decimal.equal?(summary.expected_cash, money("114500"))
    end

    test "a shift with a service still processing cannot be closed", ctx do
      tx = service_fixture(ctx.cashier, priced("10150", "1850"))

      assert Shifts.close_shift(ctx.shift, "62000") == {:error, :services_processing}
      assert Zahlungs.Repo.get!(Shifts.Shift, ctx.shift.id).status == "open"

      {:ok, _} = Zahlungs.Services.mark_success(tx, ctx.cashier, nil)

      assert {:ok, closed} = Shifts.close_shift(ctx.shift, "62000")
      assert Decimal.equal?(closed.expected_cash, money("62000"))
      assert Decimal.equal?(closed.variance, money("0"))
    end
  end
end
