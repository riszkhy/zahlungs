defmodule Zahlungs.ShiftsTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.{Shifts, Sales}

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  test "open_shift/2 opens a shift and current_shift/1 finds it" do
    user = user_fixture()
    assert is_nil(Shifts.current_shift(user))

    assert {:ok, shift} = Shifts.open_shift(user, "100000")
    assert shift.status == "open"
    assert Decimal.equal?(shift.opening_cash, Decimal.new("100000"))
    assert Shifts.current_shift(user).id == shift.id
  end

  test "cannot open a second shift while one is open" do
    user = user_fixture()
    {:ok, _} = Shifts.open_shift(user, 100_000)
    assert {:error, :already_open} = Shifts.open_shift(user, 50_000)
  end

  test "close_shift/3 computes expected cash and variance" do
    user = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)
    {:ok, shift} = Shifts.open_shift(user, "100000")

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
        amount_paid: "2000",
        shift_id: shift.id
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
    {:ok, shift} = Shifts.open_shift(user, 0)
    {:ok, closed} = Shifts.close_shift(shift, 0)
    assert {:error, :not_open} = Shifts.close_shift(closed, 0)
  end

  test "expected_cash and summary count only cash sales" do
    user = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)
    {:ok, shift} = Shifts.open_shift(user, "100000")

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        amount_paid: "1000",
        shift_id: shift.id,
        payment_method: "cash"
      })

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{
        shift_id: shift.id,
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

  test "list_shifts/1 can filter by user, and shift_sales/1 lists a shift's sales" do
    user = user_fixture()
    other = user_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 5)
    {:ok, shift} = Shifts.open_shift(user, 0)
    {:ok, _other_shift} = Shifts.open_shift(other, 0)

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
        amount_paid: "1000",
        shift_id: shift.id
      })

    mine = Shifts.list_shifts(user_id: user.id)
    assert Enum.map(mine, & &1.id) == [shift.id]

    assert [sale] = Shifts.shift_sales(shift)
    assert sale.shift_id == shift.id
  end
end
