defmodule Zahlungs.HeldCartsTest do
  @moduledoc """
  Held carts: a cart the cashier puts aside in the open shift's store and
  resumes later, from any tablet of that store. Holding touches neither stock
  nor the drawer; resuming reads prices and stock again.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Catalog, HeldCarts, Shifts}

  defp d(value), do: Decimal.new(value)

  setup do
    user = user_on_shift_fixture()
    %{user: user, shift: Shifts.current_shift(user), product: product_fixture()}
  end

  describe "hold/3" do
    test "needs an open shift", %{product: p} do
      assert HeldCarts.hold(user_fixture(), [%{product_id: p.id, quantity: 1}], %{}) ==
               {:error, :no_open_shift}
    end

    test "refuses an empty cart", %{user: user} do
      assert HeldCarts.hold(user, [], %{}) == {:error, :empty_cart}
    end

    test "keeps the items, the names and the shift's store", ctx do
      assert {:ok, held} =
               HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 2}], %{
                 "discount" => "500",
                 "tax" => ""
               })

      assert {held.store_id, held.user_id, held.shift_id} ==
               {ctx.shift.store_id, ctx.user.id, ctx.shift.id}

      assert [{ctx.product.id, 2, ctx.product.name}] ==
               Enum.map(held.items, &{&1.product_id, &1.quantity, &1.name})

      assert Decimal.equal?(held.discount, d("500"))
      assert Decimal.equal?(held.tax, d("0"))
    end

    test "a note is at most 60 characters", ctx do
      note = String.duplicate("a", 61)

      assert {:error, %Ecto.Changeset{} = changeset} =
               HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 1}], %{
                 "note" => note
               })

      assert errors_on(changeset)[:note]
    end

    test "holding touches neither stock nor the drawer", ctx do
      stock = stock_of(ctx.product)
      cash = Shifts.expected_cash(ctx.shift)

      {:ok, _} = HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 3}], %{})

      assert stock_of(ctx.product) == stock
      assert Decimal.equal?(Shifts.expected_cash(ctx.shift), cash)
    end
  end

  describe "resume/2 and delete/2" do
    defp hold!(user, lines, attrs \\ %{}) do
      items =
        Enum.map(lines, fn {product, quantity} ->
          %{product_id: product.id, quantity: quantity}
        end)

      {:ok, held} = HeldCarts.hold(user, items, attrs)
      held
    end

    test "resume gives the items back with today's prices and removes the cart", ctx do
      held = hold!(ctx.user, [{ctx.product, 2}], %{"discount" => "500"})
      {:ok, _} = Catalog.update_product(store_scope(), ctx.product, %{price: "1500"})

      assert {:ok, %{items: [%{product: product, quantity: 2}], discount: discount, adjusted: 0}} =
               HeldCarts.resume(ctx.user, held.id)

      assert product.id == ctx.product.id
      assert Decimal.equal?(product.price, d("1500"))
      assert product.stock == stock_of(ctx.product)
      assert Decimal.equal?(discount, d("500"))
      assert HeldCarts.count(ctx.user) == 0
    end

    test "a cart is resumed once", ctx do
      held = hold!(ctx.user, [{ctx.product, 1}])

      assert {:ok, _} = HeldCarts.resume(ctx.user, to_string(held.id))
      assert HeldCarts.resume(ctx.user, held.id) == {:error, :not_found}
      assert HeldCarts.resume(ctx.user, "x") == {:error, :not_found}
    end

    test "products gone or short are adjusted", ctx do
      a = ctx.product
      b = product_fixture(%{stock: 10})
      c = product_fixture()
      e = product_fixture()
      inactive = product_fixture()

      held = hold!(ctx.user, [{a, 2}, {b, 5}, {c, 1}, {inactive, 1}, {e, 1}])

      {:ok, _} = Catalog.update_product(store_scope(), b, %{stock: 3})
      {:ok, _} = Catalog.delete_product(c)
      {:ok, _} = Catalog.set_product_active(inactive, false)
      {:ok, _} = Catalog.update_product(store_scope(), e, %{stock: 0})

      assert {:ok, %{items: items, adjusted: 4}} = HeldCarts.resume(ctx.user, held.id)
      assert Enum.map(items, &{&1.product.id, &1.quantity}) == [{a.id, 2}, {b.id, 3}]
    end

    test "a cart whose products are all gone resumes empty", ctx do
      held = hold!(ctx.user, [{ctx.product, 1}])
      {:ok, _} = Catalog.delete_product(ctx.product)

      assert {:ok, %{items: [], adjusted: 1}} = HeldCarts.resume(ctx.user, held.id)
    end

    test "another store's cart can be neither resumed nor deleted", ctx do
      other = user_on_shift_fixture(%{store_id: store_fixture().id})
      held = hold!(other, [{ctx.product, 1}])

      assert HeldCarts.resume(ctx.user, held.id) == {:error, :not_found}
      assert HeldCarts.delete(ctx.user, held.id) == {:error, :not_found}
      assert HeldCarts.count(other) == 1
    end

    test "resume/3 puts the screen's cart aside in the same transaction", ctx do
      held = hold!(ctx.user, [{ctx.product, 1}])
      other = product_fixture()

      assert {:ok, %{items: [_]}} =
               HeldCarts.resume(ctx.user, held.id, {[%{product_id: other.id, quantity: 2}], %{}})

      assert [%{units: 2}] = HeldCarts.list(ctx.user)
    end

    test "a resume that finds nothing puts nothing aside", ctx do
      held = hold!(ctx.user, [{ctx.product, 1}])
      :ok = HeldCarts.delete(ctx.user, held.id)

      assert HeldCarts.resume(
               ctx.user,
               held.id,
               {[%{product_id: ctx.product.id, quantity: 1}], %{}}
             ) ==
               {:error, :not_found}

      assert HeldCarts.count(ctx.user) == 0
    end

    test "a product deleted while in the cart can still be held", ctx do
      {:ok, _} = Catalog.delete_product(ctx.product)

      assert {:ok, held} =
               HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 1}], %{})

      assert [%{name: name}] = held.items
      assert name == ctx.product.name
      assert {:ok, %{items: [], adjusted: 1}} = HeldCarts.resume(ctx.user, held.id)
    end

    test "changes are broadcast to the store", ctx do
      HeldCarts.subscribe(ctx.shift.store_id)
      held = hold!(ctx.user, [{ctx.product, 1}])
      assert_receive {:held_carts_changed, store_id}
      assert store_id == ctx.shift.store_id

      {:ok, _} = HeldCarts.resume(ctx.user, held.id)
      assert_receive {:held_carts_changed, ^store_id}

      held = hold!(ctx.user, [{ctx.product, 1}])
      assert_receive {:held_carts_changed, ^store_id}
      :ok = HeldCarts.delete(ctx.user, held.id)
      assert_receive {:held_carts_changed, ^store_id}
    end

    test "delete removes the cart and its items", ctx do
      held = hold!(ctx.user, [{ctx.product, 1}])

      assert HeldCarts.delete(ctx.user, held.id) == :ok
      assert HeldCarts.count(ctx.user) == 0
      assert HeldCarts.delete(ctx.user, held.id) == {:error, :not_found}
      assert HeldCarts.delete(user_fixture(), held.id) == {:error, :no_open_shift}
    end
  end

  describe "list/1 and count/1" do
    test "list the store's held carts, newest first, priced now", ctx do
      {:ok, older} =
        HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 2}], %{
          "note" => "Bu Ani",
          "discount" => "500",
          "tax" => "100"
        })

      {:ok, newer} = HeldCarts.hold(ctx.user, [%{product_id: ctx.product.id, quantity: 1}], %{})

      {:ok, _} =
        Catalog.update_product(store_scope(), ctx.product, %{price: "2000"})

      assert [first, second] =
               ctx.user |> HeldCarts.list() |> Enum.filter(&(&1.id in [older.id, newer.id]))

      assert first.id == newer.id
      assert second.note == "Bu Ani"
      assert second.units == 2
      # 2 × 2.000 − 500 + 100
      assert Decimal.equal?(second.total, d("3600"))
      assert HeldCarts.count(ctx.user) == 2
    end

    test "see only the shift's store", ctx do
      other = user_on_shift_fixture(%{store_id: store_fixture().id})
      {:ok, theirs} = HeldCarts.hold(other, [%{product_id: ctx.product.id, quantity: 1}], %{})

      assert HeldCarts.count(ctx.user) == 0
      refute theirs.id in Enum.map(HeldCarts.list(ctx.user), & &1.id)
      assert HeldCarts.count(other) == 1
      assert HeldCarts.count(user_fixture()) == 0
      assert HeldCarts.list(user_fixture()) == []
    end
  end
end
