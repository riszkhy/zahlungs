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
    from(p in Product, where: is_nil(p.deleted_at))
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

      where(
        query,
        [p],
        like(p.name, ^pattern) or like(p.sku, ^pattern) or like(p.barcode, ^pattern)
      )
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

  @doc "Gets a single (non-deleted) product (raises if not found). Preloads category."
  def get_product!(id) do
    from(p in Product, where: is_nil(p.deleted_at))
    |> Repo.get!(id)
    |> Repo.preload(:category)
  end

  @doc "Counts products matching the given options (same filters as `list_products/1`)."
  def count_products(opts \\ []) do
    opts
    |> base_query()
    |> Repo.aggregate(:count)
  end

  @doc "Lists products whose stock is at or below the given threshold."
  def list_low_stock_products(threshold \\ 5) do
    Product
    |> where([p], is_nil(p.deleted_at) and p.active == true and p.stock <= ^threshold)
    |> order_by([p], asc: p.stock)
    |> Repo.all()
  end

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(maybe_put_sku(attrs))
    |> Repo.insert()
  end

  # Auto-generates the SKU when none is supplied (the normal case from the form).
  defp maybe_put_sku(attrs) do
    if blank?(attrs[:sku] || attrs["sku"]) do
      sku = generate_sku(attrs[:category_id] || attrs["category_id"])
      if Enum.any?(Map.keys(attrs), &is_atom/1) or attrs == %{},
        do: Map.put(attrs, :sku, sku),
        else: Map.put(attrs, "sku", sku)
    else
      attrs
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft-deletes a product (sets `deleted_at`); the row is kept for history."
  def delete_product(%Product{} = product) do
    product
    |> Ecto.Changeset.change(deleted_at: now())
    |> Repo.update()
  end

  @doc "Activates/deactivates a product by toggling its `active` flag."
  def set_product_active(%Product{} = product, active) when is_boolean(active) do
    product
    |> Product.changeset(%{active: active})
    |> Repo.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  @doc """
  Generates a SKU: 3 consonant letters from the category name (padded with `X`
  if needed; `GEN` when there is no category) followed by a zero-padded counter
  of at least 3 digits, unique per prefix.

  ## Examples

      iex> generate_sku(drinks_category_id)
      "DRN001"
  """
  def generate_sku(category_id) do
    prefix = sku_prefix(to_id(category_id))
    counter = next_sku_counter(prefix)
    prefix <> String.pad_leading(Integer.to_string(counter), 3, "0")
  end

  defp sku_prefix(nil), do: "GEN"

  defp sku_prefix(category_id) do
    case Repo.get(Category, category_id) do
      %Category{name: name} -> consonant_prefix(name)
      _ -> "GEN"
    end
  end

  defp consonant_prefix(name) do
    consonants =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "")
      |> String.replace(~r/[AEIOU]/, "")

    String.slice(consonants <> "XXX", 0, 3)
  end

  # Highest existing counter for the prefix + 1 (considers soft-deleted rows too,
  # since the unique index spans them).
  defp next_sku_counter(prefix) do
    pattern = prefix <> "%"

    numbers =
      from(p in Product, where: like(p.sku, ^pattern), select: p.sku)
      |> Repo.all()
      |> Enum.map(fn sku ->
        case Regex.run(~r/(\d+)$/, sku) do
          [_, digits] -> String.to_integer(digits)
          _ -> 0
        end
      end)

    Enum.max([0 | numbers]) + 1
  end

  defp to_id(nil), do: nil
  defp to_id(id) when is_integer(id), do: id
  defp to_id(""), do: nil

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  @doc """
  Computes the selling price from a purchase price and margin percentage:

      price = purchase_price * (1 + margin_percent / 100)

  Accepts decimals, integers or strings. Result is rounded to 2 decimals.

  ## Examples

      iex> compute_price("1000", "20")
      Decimal.new("1200.00")
  """
  def compute_price(purchase_price, margin_percent) do
    pp = to_decimal(purchase_price)
    margin = to_decimal(margin_percent)

    pp
    |> Decimal.mult(Decimal.add(Decimal.new(1), Decimal.div(margin, Decimal.new(100))))
    |> Decimal.round(2)
  end

  @doc """
  Computes the margin percentage from a selling price and purchase price:

      margin = (selling_price - purchase_price) / purchase_price * 100

  Returns `0` when the purchase price is not positive. Rounded to 2 decimals.

  ## Examples

      iex> compute_margin("1200", "1000")
      Decimal.new("20.00")
  """
  def compute_margin(selling_price, purchase_price) do
    sp = to_decimal(selling_price)
    pp = to_decimal(purchase_price)

    if Decimal.gt?(pp, Decimal.new(0)) do
      sp
      |> Decimal.sub(pp)
      |> Decimal.div(pp)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  defp to_decimal(s) when is_binary(s) do
    case s |> String.trim() |> Decimal.parse() do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  ## Categories

  defp categories_query, do: from(c in Category, where: is_nil(c.deleted_at))

  @doc "Lists all (non-deleted) categories ordered by name."
  def list_categories do
    categories_query() |> order_by(:name) |> Repo.all()
  end

  @doc "Returns `{name, id}` tuples for use in select inputs."
  def category_options do
    categories_query()
    |> order_by(:name)
    |> select([c], {c.name, c.id})
    |> Repo.all()
  end

  def get_category!(id), do: categories_query() |> Repo.get!(id)

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

  @doc "Soft-deletes a category (sets `deleted_at`); the row is kept."
  def delete_category(%Category{} = category) do
    category
    |> Ecto.Changeset.change(deleted_at: now())
    |> Repo.update()
  end

  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
