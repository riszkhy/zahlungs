defmodule Zahlungs.Services do
  @moduledoc """
  PPOB services (Fase 0, no provider API): the products a store sells besides
  goods, and their price.

  ## Price

  `margin(x)` is the product's rupiah margin, or `x × percent / 100` rounded up
  to the whole rupiah.

    * pulsa, paket data, token PLN: cost = the product's cost,
      price = cost + margin(cost).
    * tagihan PLN: cost = bill + provider fee (the product's cost),
      price = bill + margin(bill) — the margin is the admin fee.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Services.Product

  @category_labels [
    {"pulsa", "Pulsa"},
    {"paket_data", "Paket data"},
    {"token_pln", "Token PLN"},
    {"tagihan_pln", "Tagihan PLN"}
  ]

  @doc "The categories as `{value, label}` pairs, in display order."
  def categories, do: @category_labels

  ## Products

  @doc """
  Lists products that aren't deleted, by name.

  Options: `:category`, `:active` (`true`/`false`).
  """
  def list_products(opts \\ []) do
    Product
    |> where([p], is_nil(p.deleted_at))
    |> filter(:category, opts[:category])
    |> filter(:active, opts[:active])
    |> order_by([p], p.name)
    |> Repo.all()
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, _field, ""), do: query
  defp filter(query, :category, category), do: where(query, [p], p.category == ^category)
  defp filter(query, :active, active), do: where(query, [p], p.active == ^active)

  @doc "Gets a product that isn't deleted (raises otherwise)."
  def get_product!(id) do
    Repo.one!(from p in Product, where: p.id == ^id and is_nil(p.deleted_at))
  end

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft delete: hidden from lists, kept for the transactions that name it."
  def delete_product(%Product{} = product) do
    product
    |> Ecto.Changeset.change(deleted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second))
    |> Repo.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  ## Price

  @doc """
  The price to the customer and the cost to the shop, for a product and (for
  tagihan PLN) the bill. A bill without a positive amount has no price.
  """
  def price_for(%Product{} = product, bill_amount) do
    if Product.bill?(product) do
      bill = to_decimal(bill_amount)

      if Decimal.gt?(bill, 0) do
        {:ok,
         %{price: Decimal.add(bill, margin(product, bill)), cost: Decimal.add(bill, product.cost)}}
      else
        {:error, :bill_required}
      end
    else
      {:ok,
       %{price: Decimal.add(product.cost, margin(product, product.cost)), cost: product.cost}}
    end
  end

  defp margin(%Product{margin_type: "percent", margin_value: percent}, base) do
    base |> Decimal.mult(percent) |> Decimal.div(100) |> Decimal.round(0, :ceiling)
  end

  defp margin(%Product{margin_value: amount}, _base), do: amount

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)

  defp to_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {d, ""} -> d
      _ -> Decimal.new(0)
    end
  end
end
