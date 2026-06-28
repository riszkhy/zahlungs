defmodule Zahlungs.Catalog do
  @moduledoc """
  The Catalog context: products and categories.

  This is the public API for everything product-related. LiveViews and tests call
  these functions, never the schemas directly.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Catalog.{Category, Product}

  ## Products

  @doc """
  Lists products.

  ## Options

    * `:search` - filters by name or SKU (case-insensitive, substring match)
    * `:category_id` - filters by category
    * `:active` - filters by active flag (`true`/`false`); omit for all
    * `:in_stock` - when `true`, only products with stock > 0
    * `:order_by` - column to order by (defaults to `:name`)
    * `:limit` / `:offset` - pagination

  Results preload the associated category.
  """
  def list_products(opts \\ []) do
    opts
    |> base_query()
    |> order_by(^(opts[:order_by] || :name))
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> preload(:category)
    |> Repo.all()
  end

  defp base_query(opts) do
    Product
    |> filter_search(opts[:search])
    |> filter_category(opts[:category_id])
    |> filter_active(opts[:active])
    |> filter_in_stock(opts[:in_stock])
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, 0), do: query
  defp maybe_offset(query, n), do: offset(query, ^n)

  defp filter_in_stock(query, true), do: where(query, [p], p.stock > 0)
  defp filter_in_stock(query, _), do: query

  defp filter_search(query, term) when is_binary(term) do
    trimmed = String.trim(term)

    if trimmed == "" do
      query
    else
      pattern = "%#{trimmed}%"
      where(query, [p], like(p.name, ^pattern) or like(p.sku, ^pattern))
    end
  end

  defp filter_search(query, _), do: query

  defp filter_category(query, nil), do: query
  defp filter_category(query, ""), do: query

  defp filter_category(query, category_id) do
    where(query, [p], p.category_id == ^category_id)
  end

  defp filter_active(query, active) when is_boolean(active) do
    where(query, [p], p.active == ^active)
  end

  defp filter_active(query, _), do: query

  @doc "Gets a single product (raises if not found). Preloads category."
  def get_product!(id), do: Product |> Repo.get!(id) |> Repo.preload(:category)

  @doc "Counts products matching the given options (same filters as `list_products/1`)."
  def count_products(opts \\ []) do
    opts
    |> base_query()
    |> Repo.aggregate(:count)
  end

  @doc "Lists products whose stock is at or below the given threshold."
  def list_low_stock_products(threshold \\ 5) do
    Product
    |> where([p], p.active == true and p.stock <= ^threshold)
    |> order_by([p], asc: p.stock)
    |> Repo.all()
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

  @doc "Hard-deletes a product."
  def delete_product(%Product{} = product), do: Repo.delete(product)

  @doc "Soft-deletes / restores a product by toggling its `active` flag."
  def set_product_active(%Product{} = product, active) when is_boolean(active) do
    product
    |> Product.changeset(%{active: active})
    |> Repo.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  ## Categories

  @doc "Lists all categories ordered by name."
  def list_categories do
    Category |> order_by(:name) |> Repo.all()
  end

  @doc "Returns `{name, id}` tuples for use in select inputs."
  def category_options do
    Category
    |> order_by(:name)
    |> select([c], {c.name, c.id})
    |> Repo.all()
  end

  def get_category!(id), do: Repo.get!(Category, id)

  def create_category(attrs \\ %{}) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> Repo.update()
  end

  def delete_category(%Category{} = category), do: Repo.delete(category)

  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end
end
