defmodule Zahlungs.PromotionsTest do
  @moduledoc """
  Promotions: percent or rupiah discounts on products or categories, for a
  date range, in all stores or chosen ones. One per sale line, the largest;
  consignment products never get one.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.PromotionsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, LocalTime, Promotions}

  defp d(value), do: Decimal.new(value)

  defp admin do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp today, do: LocalTime.today(default_store())

  defp attrs(extra) do
    Map.merge(
      %{
        "name" => "Promo #{System.unique_integer([:positive])}",
        "kind" => "percent",
        "value" => "10",
        "starts_on" => Date.to_iso8601(today()),
        "ends_on" => Date.to_iso8601(Date.add(today(), 7))
      },
      extra
    )
  end

  describe "promotions" do
    test "an admin creates one on products and categories" do
      product = product_fixture()
      category = category_fixture()

      assert {:ok, promotion} =
               Promotions.create_promotion(
                 admin(),
                 attrs(%{
                   "product_ids" => [to_string(product.id)],
                   "category_ids" => [to_string(category.id)]
                 })
               )

      promotion = Promotions.get_promotion!(promotion.id)
      assert promotion.product_ids == [product.id]
      assert promotion.category_ids == [category.id]
      assert promotion.all_stores
    end

    test "only an admin manages promotions" do
      product = product_fixture()

      assert Promotions.create_promotion(user_fixture(), attrs(%{"product_ids" => [product.id]})) ==
               {:error, :unauthorized}

      promotion = promotion_fixture()

      assert Promotions.update_promotion(user_fixture(), promotion, %{"name" => "x"}) ==
               {:error, :unauthorized}

      assert Promotions.set_active(user_fixture(), promotion, false) == {:error, :unauthorized}
    end

    test "invalid promotions are refused" do
      product = product_fixture()
      admin = admin()

      assert {:error, cs} =
               Promotions.create_promotion(
                 admin,
                 attrs(%{"value" => "101", "product_ids" => [product.id]})
               )

      assert errors_on(cs)[:value]

      assert {:error, cs} =
               Promotions.create_promotion(
                 admin,
                 attrs(%{
                   "ends_on" => Date.to_iso8601(Date.add(today(), -1)),
                   "product_ids" => [product.id]
                 })
               )

      assert errors_on(cs)[:ends_on]

      assert {:error, cs} = Promotions.create_promotion(admin, attrs(%{}))
      assert errors_on(cs)[:product_ids]

      assert {:error, cs} =
               Promotions.create_promotion(
                 admin,
                 attrs(%{"all_stores" => "false", "product_ids" => [product.id]})
               )

      assert errors_on(cs)[:store_ids]
    end

    test "another organization's product can't be a target" do
      # The default organization first, so the product below is the other's.
      admin = admin()

      theirs =
        in_org(organization_fixture(), fn ->
          {:ok, product} =
            Zahlungs.Catalog.create_product(Zahlungs.Scope.for_store(store_fixture()), %{
              name: "Asing",
              sku: unique_sku(),
              price: Decimal.new("1000"),
              stock: 1
            })

          product
        end)

      name = "Asing #{System.unique_integer([:positive])}"

      assert {:error, cs} =
               Promotions.create_promotion(
                 admin,
                 attrs(%{"name" => name, "product_ids" => [theirs.id]})
               )

      assert errors_on(cs)[:product_ids]
      refute Enum.any?(Promotions.list_promotions(), &(&1.promotion.name == name))
    end

    test "an update replaces the targets and the stores" do
      promotion = promotion_fixture()
      other = product_fixture()
      store = default_store()

      assert {:ok, _} =
               Promotions.update_promotion(admin(), promotion, %{
                 "product_ids" => [other.id],
                 "all_stores" => "false",
                 "store_ids" => [to_string(store.id)]
               })

      promotion = Promotions.get_promotion!(promotion.id)
      assert promotion.product_ids == [other.id]
      assert promotion.store_ids == [store.id]
      refute promotion.all_stores
    end

    test "the list says which promotions run, are coming, ended or are off" do
      t = LocalTime.today(nil)
      running = promotion_fixture(%{starts_on: t, ends_on: t})
      coming = promotion_fixture(%{starts_on: Date.add(t, 1), ends_on: Date.add(t, 2)})
      ended = promotion_fixture(%{starts_on: Date.add(t, -3), ends_on: Date.add(t, -1)})
      off = promotion_fixture(%{starts_on: t, ends_on: t, active: false})

      status = Map.new(Promotions.list_promotions(), &{&1.promotion.id, &1.status})

      assert status[running.id] == :running
      assert status[coming.id] == :scheduled
      assert status[ended.id] == :ended
      assert status[off.id] == :inactive
    end

    test "the limit on a cashier's manual discount" do
      admin = admin()
      org_id = admin.organization_id

      assert Promotions.cashier_discount_limit(org_id) == nil
      assert {:ok, _} = Promotions.set_cashier_discount_limit(admin, "10")
      assert Decimal.equal?(Promotions.cashier_discount_limit(org_id), d("10"))
      assert Promotions.set_cashier_discount_limit(user_fixture(), "5") == {:error, :unauthorized}
      assert {:error, %Ecto.Changeset{}} = Promotions.set_cashier_discount_limit(admin, "101")
      assert {:ok, _} = Promotions.set_cashier_discount_limit(admin, "")
      assert Promotions.cashier_discount_limit(org_id) == nil
    end
  end

  describe "engine" do
    alias Zahlungs.Promotions.{Promotion, PromotionTarget}

    defp promo(id, kind, value, targets) do
      %Promotion{
        id: id,
        name: "P#{id}",
        kind: kind,
        value: d(value),
        targets:
          Enum.map(targets, fn {field, target} -> struct(PromotionTarget, [{field, target}]) end)
      }
    end

    defp line(price, qty, product \\ %{id: 1, category_id: 9, consignment: false}),
      do: %{product: product, quantity: qty, unit_price: d(price)}

    defp discount_of(lines, promos), do: lines |> Promotions.apply(promos) |> hd()

    test "percent is floored to the rupiah" do
      assert Decimal.equal?(
               discount_of([line("12350", 1)], [promo(1, "percent", "10", product_id: 1)]).discount,
               d("1235")
             )

      assert Decimal.equal?(
               discount_of([line("12355", 1)], [promo(1, "percent", "10", product_id: 1)]).discount,
               d("1235")
             )
    end

    test "rupiah is per unit and never more than the line" do
      assert Decimal.equal?(
               discount_of([line("10000", 3)], [promo(1, "amount", "2000", product_id: 1)]).discount,
               d("6000")
             )

      assert Decimal.equal?(
               discount_of([line("3000", 1)], [promo(1, "amount", "5000", product_id: 1)]).discount,
               d("3000")
             )
    end

    test "the largest discount wins, a tie goes to the older promotion" do
      promos = [
        promo(1, "percent", "5", product_id: 1),
        promo(2, "amount", "1000", category_id: 9)
      ]

      result = discount_of([line("10000", 1)], promos)

      assert Decimal.equal?(result.discount, d("1000"))
      assert {result.promotion_id, result.promotion_name} == {2, "P2"}

      tie = [promo(7, "amount", "500", product_id: 1), promo(3, "amount", "500", category_id: 9)]
      assert discount_of([line("10000", 1)], tie).promotion_id == 3
    end

    test "consignment products and lines without a promotion get nothing" do
      consigned = line("10000", 1, %{id: 1, category_id: 9, consignment: true})
      result = discount_of([consigned], [promo(1, "percent", "10", product_id: 1)])

      assert {Decimal.to_integer(result.discount), result.promotion_id, result.promotion_name} ==
               {0, nil, nil}

      other = line("10000", 1, %{id: 2, category_id: 8, consignment: false})
      assert discount_of([other], [promo(1, "percent", "10", product_id: 1)]).promotion_id == nil
    end

    test "active_for: the first and last day count, in the store's local date" do
      store = default_store()
      t = today()
      product = product_fixture()
      ids = [product.id]

      today_only = promotion_fixture(%{product_ids: ids, starts_on: t, ends_on: t})

      ended =
        promotion_fixture(%{
          product_ids: ids,
          starts_on: Date.add(t, -5),
          ends_on: Date.add(t, -1)
        })

      coming =
        promotion_fixture(%{product_ids: ids, starts_on: Date.add(t, 1), ends_on: Date.add(t, 5)})

      off = promotion_fixture(%{product_ids: ids, starts_on: t, ends_on: t, active: false})

      elsewhere =
        promotion_fixture(%{
          product_ids: ids,
          starts_on: t,
          ends_on: t,
          all_stores: false,
          store_ids: [store_fixture().id]
        })

      here =
        promotion_fixture(%{
          product_ids: ids,
          starts_on: t,
          ends_on: t,
          all_stores: false,
          store_ids: [store.id]
        })

      found = store |> Promotions.active_for(t) |> Enum.map(& &1.id)

      assert today_only.id in found
      assert here.id in found
      refute Enum.any?([ended.id, coming.id, off.id, elsewhere.id], &(&1 in found))

      assert [%Promotion{targets: [%PromotionTarget{product_id: product_id}]} | _] =
               Promotions.active_for(store, t)

      assert product_id == product.id
    end

    test "active_for: another organization's promotions are not seen" do
      promotion = promotion_fixture()

      in_org(organization_fixture(), fn ->
        refute promotion.id in Enum.map(Promotions.active_for(nil, today()), & &1.id)
      end)
    end
  end

  describe "sales" do
    import Zahlungs.ShiftsFixtures

    alias Zahlungs.{Customers, Sales}

    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("10000"), stock: 20)
      promotion = promotion_fixture(%{product_ids: [product.id]})
      %{user: user, product: product, promotion: promotion}
    end

    defp sell(user, product, qty, payment \\ %{}) do
      Sales.create_sale(
        user,
        [%{product_id: product.id, quantity: qty}],
        Map.merge(%{amount_paid: "1000000"}, payment)
      )
    end

    test "a sale takes each line's promotion off and keeps it on the line", ctx do
      assert {:ok, sale} = sell(ctx.user, ctx.product, 2)
      assert [item] = sale.items

      assert Decimal.equal?(item.discount, d("2000"))
      assert Decimal.equal?(item.line_total, d("18000"))
      assert Decimal.equal?(item.unit_price, d("10000"))
      assert {item.promotion_id, item.promotion_name} == {ctx.promotion.id, ctx.promotion.name}
      assert Decimal.equal?(sale.subtotal, d("18000"))
      assert Decimal.equal?(sale.total, d("18000"))
    end

    test "the sale works the promotion out itself", ctx do
      {:ok, _} = Promotions.set_active(promo_admin(), ctx.promotion, false)

      assert {:ok, %{items: [item]}} = sell(ctx.user, ctx.product, 2)
      assert Decimal.equal?(item.discount, d("0"))
      assert item.promotion_id == nil
    end

    test "another store's promotion and consignment products get nothing", ctx do
      {:ok, _} =
        Promotions.update_promotion(promo_admin(), ctx.promotion, %{
          all_stores: false,
          store_ids: [store_fixture().id]
        })

      assert {:ok, %{items: [item]}} = sell(ctx.user, ctx.product, 1)
      assert Decimal.equal?(item.discount, d("0"))

      consigned =
        product_fixture(
          price: Decimal.new("10000"),
          consignment: true,
          supplier_id: supplier_fixture().id
        )

      promotion_fixture(%{product_ids: [consigned.id]})
      assert {:ok, %{items: [item]}} = sell(ctx.user, consigned, 1)
      assert Decimal.equal?(item.discount, d("0"))
    end

    test "a cashier's manual discount is limited, an admin's isn't", ctx do
      {:ok, _} = Promotions.set_cashier_discount_limit(promo_admin(), "10")
      stock = stock_of(ctx.product)

      # Subtotal after the promotion: 18.000, so 10% is 1.800.
      assert sell(ctx.user, ctx.product, 2, %{discount: "1801"}) == {:error, :discount_over_limit}
      assert stock_of(ctx.product) == stock
      assert {:ok, _} = sell(ctx.user, ctx.product, 2, %{discount: "1800"})

      {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
      Zahlungs.ShiftsFixtures.shift_fixture(admin)
      assert {:ok, _} = sell(admin, ctx.product, 2, %{discount: "5000"})
    end

    test "a credit sale owes the total after the promotion", ctx do
      customer = Zahlungs.CustomersFixtures.customer_fixture()

      {:ok, _} =
        sell(ctx.user, ctx.product, 2, %{
          payment_method: "credit",
          customer_id: customer.id,
          amount_paid: "",
          due_date: Date.add(today(), 30)
        })

      assert Decimal.equal?(Customers.balance(customer), d("18000"))
    end

    test "reports show what promotions took off", ctx do
      {:ok, _} = sell(ctx.user, ctx.product, 2)
      plain = product_fixture(price: Decimal.new("5000"), stock: 5)
      {:ok, %{items: [plain_item]}} = sell(ctx.user, plain, 1)

      assert Decimal.equal?(plain_item.discount, d("0"))
      assert Decimal.equal?(plain_item.line_total, d("5000"))

      report = Sales.sales_report(store_scope(), today(), today())
      assert Decimal.equal?(report.promo_discount, d("2000"))
      assert Decimal.equal?(report.gross_sales, d("23000"))

      assert [row] = Promotions.report(store_scope(), today(), today())
      assert {row.promotion_id, row.name, row.items} == {ctx.promotion.id, ctx.promotion.name, 2}
      assert Decimal.equal?(row.discount, d("2000"))
      assert Decimal.equal?(row.revenue, d("18000"))
    end
  end

  describe "saving and selling, safely" do
    import Zahlungs.ShiftsFixtures

    alias Zahlungs.Sales

    defp queries_of(fun) do
      test_pid = self()
      handler = "promo-queries-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:zahlungs, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == test_pid, do: send(test_pid, {:query, meta.query})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      collect([])
    end

    defp collect(acc) do
      receive do
        {:query, query} -> collect([query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # A DELETE by promotion_id gap-locks the index under REPEATABLE READ, and
    # two admins saving at once then deadlock on the inserts that follow.
    test "saving a promotion deletes old links by their own ids only" do
      product = product_fixture()

      created =
        queries_of(fn ->
          {:ok, _} =
            Promotions.create_promotion(promo_admin(), %{
              name: "Baru #{System.unique_integer([:positive])}",
              kind: "percent",
              value: "5",
              starts_on: today(),
              ends_on: today(),
              product_ids: [product.id]
            })
        end)

      refute Enum.any?(created, &(&1 =~ "DELETE"))

      promotion = promotion_fixture()

      updated =
        queries_of(fn ->
          {:ok, _} =
            Promotions.update_promotion(promo_admin(), promotion, %{product_ids: [product.id]})
        end)

      deletes = Enum.filter(updated, &(&1 =~ "DELETE"))
      assert deletes != []
      refute Enum.any?(deletes, &(&1 =~ "`promotion_id`"))
      assert Promotions.get_promotion!(promotion.id).product_ids == [product.id]
    end

    test "a sale whose total differs from the screen's is refused" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("10000"), stock: 5)
      promotion_fixture(%{product_ids: [product.id]})
      cart = [%{product_id: product.id, quantity: 1}]

      assert Sales.create_sale(user, cart, %{amount_paid: "10000", expected_total: "10000"}) ==
               {:error, :prices_changed}

      assert stock_of(product) == 5

      assert {:ok, _} =
               Sales.create_sale(user, cart, %{amount_paid: "9000", expected_total: "9000"})
    end
  end
end
