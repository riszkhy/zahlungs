defmodule Zahlungs.ServicesTest do
  @moduledoc """
  PPOB services (Fase 0): products and their price, recording a service when
  the money is taken, and marking it done or failed.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Product

  defp d(value), do: Decimal.new(value)

  defp product(attrs), do: struct(Product, Map.new(attrs))

  defp assert_price(result, price, cost) do
    assert {:ok, %{price: got_price, cost: got_cost}} = result
    assert Decimal.equal?(got_price, d(price)), "price #{got_price}, expected #{price}"
    assert Decimal.equal?(got_cost, d(cost)), "cost #{got_cost}, expected #{cost}"
  end

  describe "price_for/2" do
    test "a fixed-value product is its cost plus a rupiah margin" do
      token =
        product(
          category: "token_pln",
          cost: d("50150"),
          margin_type: "amount",
          margin_value: d("2350")
        )

      assert_price(Services.price_for(token, nil), "52500", "50150")
    end

    test "a percent margin is rounded up to the whole rupiah" do
      pulsa =
        product(
          category: "pulsa",
          cost: d("10150"),
          margin_type: "percent",
          margin_value: d("15")
        )

      # 10150 × 1.15 = 11672.5
      assert_price(Services.price_for(pulsa, nil), "11673", "10150")
    end

    test "a bill is the bill plus the admin fee; its cost the bill plus the provider fee" do
      fixed =
        product(
          category: "tagihan_pln",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      assert_price(Services.price_for(fixed, d("245000")), "248000", "246500")

      percent =
        product(
          category: "tagihan_pln",
          cost: d("1500"),
          margin_type: "percent",
          margin_value: d("1")
        )

      assert_price(Services.price_for(percent, d("245000")), "247450", "246500")
    end

    test "a bill without its amount has no price" do
      bill =
        product(
          category: "tagihan_pln",
          cost: d("1500"),
          margin_type: "amount",
          margin_value: d("3000")
        )

      assert Services.price_for(bill, nil) == {:error, :bill_required}
      assert Services.price_for(bill, d("0")) == {:error, :bill_required}
    end
  end

  describe "products" do
    test "validates the category, the margin and the cost" do
      assert {:error, changeset} =
               Services.create_product(%{name: "X", category: "game", cost: "1"})

      assert errors_on(changeset)[:category]

      assert {:error, changeset} =
               Services.create_product(%{
                 name: "X",
                 category: "pulsa",
                 cost: "10000",
                 margin_value: "-1"
               })

      assert errors_on(changeset)[:margin_value]

      assert {:error, changeset} =
               Services.create_product(%{name: "X", category: "pulsa", cost: "0"})

      assert errors_on(changeset)[:cost]

      assert {:ok, _bill} =
               Services.create_product(%{name: "Tagihan PLN", category: "tagihan_pln", cost: "0"})
    end

    test "a deleted product is no longer listed or found" do
      product = service_product_fixture()
      assert product.id in Enum.map(Services.list_products(), & &1.id)

      {:ok, _} = Services.delete_product(product)

      refute product.id in Enum.map(Services.list_products(), & &1.id)
      assert_raise Ecto.NoResultsError, fn -> Services.get_product!(product.id) end
    end

    test "lists by category and active flag" do
      pulsa = service_product_fixture(%{category: "pulsa"})
      token = service_product_fixture(%{category: "token_pln", active: false})

      assert pulsa.id in Enum.map(Services.list_products(category: "pulsa"), & &1.id)
      refute token.id in Enum.map(Services.list_products(category: "pulsa"), & &1.id)
      refute token.id in Enum.map(Services.list_products(active: true), & &1.id)
    end

    test "another organization's products are invisible" do
      other = in_org(organization_fixture(), fn -> service_product_fixture() end)

      refute other.id in Enum.map(Services.list_products(), & &1.id)
      assert_raise Ecto.NoResultsError, fn -> Services.get_product!(other.id) end
    end
  end
end
