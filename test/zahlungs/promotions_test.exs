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
end
