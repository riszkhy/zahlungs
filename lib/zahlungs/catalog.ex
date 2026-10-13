defmodule Zahlungs.Catalog do
  @moduledoc """
  The Catalog context: products, categories and suppliers.

  This is the public API for everything product-related. LiveViews and tests call
  these functions, never the schemas directly.

  ## Stock is per store

  The catalog itself is shared by all stores, but stock is not: it lives in
  `product_stocks`, one row per store and product (no row means zero).
  Functions that read or write stock take a `Zahlungs.Scope` and fill the
  product's `stock` field with the units in that scope's store — or the sum over
  all stores for an admin looking at all of them.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Catalog.{Category, Product, ProductStock, Supplier}
  alias Zahlungs.Scope

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
  def list_products(%Scope{} = scope, opts \\ []) do
    scope
    |> base_query(opts)
    |> order_by(^(opts[:order_by] || :name))
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> with_stock()
    |> preload(:category)
    |> Repo.all()
  end

  defp base_query(scope, opts) do
    scope
    |> products_query()
    |> filter_search(opts[:search])
    |> filter_category(opts[:category_id])
    |> filter_active(opts[:active])
    |> filter_in_stock(opts[:in_stock])
  end

  # Non-deleted products joined with their stock in the scope's store, as the
  # named binding `:stock` (nil when the store has no row for the product).
  defp products_query(scope) do
    from p in Product,
      left_join: st in subquery(stock_query(scope)),
      as: :stock,
      on: st.product_id == p.id,
      where: is_nil(p.deleted_at)
  end

  defp stock_query(scope) do
    case Scope.store_id(scope) do
      nil ->
        from ps in ProductStock,
          group_by: ps.product_id,
          select: %{product_id: ps.product_id, stock: sum(ps.stock)}

      store_id ->
        from ps in ProductStock,
          where: ps.store_id == ^store_id,
          select: %{product_id: ps.product_id, stock: ps.stock}
    end
  end

  # Fills the virtual `stock` field from the joined stock.
  defp with_stock(query) do
    select_merge(query, [stock: st], %{stock: type(coalesce(st.stock, 0), :integer)})
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, 0), do: query
  defp maybe_offset(query, n), do: offset(query, ^n)

  defp filter_in_stock(query, true), do: where(query, [stock: st], coalesce(st.stock, 0) > 0)
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
  def get_product!(%Scope{} = scope, id) do
    scope
    |> products_query()
    |> with_stock()
    |> Repo.get!(id)
    |> Repo.preload(:category)
  end

  @doc """
  Finds a single active, non-deleted product by an exact barcode or SKU match
  (used by the cashier barcode scanner). Returns the product (category preloaded)
  or `nil`.
  """
  def get_product_by_code(%Scope{} = scope, code) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed == "" do
      nil
    else
      scope
      |> products_query()
      |> where([p], p.active == true and (p.barcode == ^trimmed or p.sku == ^trimmed))
      |> limit(1)
      |> with_stock()
      |> Repo.all()
      |> List.first()
      |> case do
        nil -> nil
        product -> Repo.preload(product, :category)
      end
    end
  end

  def get_product_by_code(%Scope{}, _), do: nil

  @doc "Counts products matching the given options (same filters as `list_products/2`)."
  def count_products(%Scope{} = scope, opts \\ []) do
    scope
    |> base_query(opts)
    |> Repo.aggregate(:count)
  end

  @doc "Lists products whose stock is at or below the given threshold."
  def list_low_stock_products(%Scope{} = scope, threshold \\ 5) do
    scope
    |> products_query()
    |> where([p, stock: st], p.active == true and coalesce(st.stock, 0) <= ^threshold)
    |> order_by([stock: st], asc: coalesce(st.stock, 0))
    |> with_stock()
    |> Repo.all()
  end

  @doc """
  Current inventory snapshot for active products: counts, stock value at cost and
  retail (potential profit), plus low-stock and out-of-stock product lists.
  """
  def stock_report(%Scope{} = scope, threshold \\ 5) do
    base = scope |> products_query() |> where([p], p.active == true)

    summary =
      Repo.one(
        from [p, stock: st] in base,
          select: %{
            products: count(p.id),
            units: coalesce(sum(st.stock), 0),
            cost_value: coalesce(sum(fragment("? * ?", p.purchase_price, st.stock)), 0),
            retail_value: coalesce(sum(fragment("? * ?", p.price, st.stock)), 0)
          }
      )

    low =
      base
      |> where([stock: st], st.stock > 0 and st.stock <= ^threshold)
      |> order_by([stock: st], asc: st.stock)
      |> with_stock()
      |> Repo.all()
      |> Repo.preload(:category)

    out =
      base
      |> where([stock: st], coalesce(st.stock, 0) <= 0)
      |> order_by([p], asc: p.name)
      |> with_stock()
      |> Repo.all()
      |> Repo.preload(:category)

    cost = to_decimal(summary.cost_value)
    retail = to_decimal(summary.retail_value)

    %{
      products: summary.products,
      units: to_integer(summary.units),
      cost_value: cost,
      retail_value: retail,
      potential_profit: Decimal.sub(retail, cost),
      low_stock: low,
      out_of_stock: out
    }
  end

  @doc """
  Creates a product. A `stock` attribute becomes the stock in the scope's
  store; the product starts at zero everywhere else.
  """
  def create_product(%Scope{} = scope, attrs \\ %{}) do
    %Product{}
    |> Product.changeset(maybe_put_sku(attrs))
    |> save_with_stock(scope, &Repo.insert/1)
  end

  # Saves the product and, when the changeset sets `stock`, writes it for the
  # scope's store — both or neither.
  defp save_with_stock(changeset, scope, save) do
    Repo.transaction(fn ->
      with {:ok, product} <- save.(changeset),
           :ok <- put_stock(scope, product, changeset) do
        product
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp put_stock(scope, product, changeset) do
    case {Ecto.Changeset.fetch_change(changeset, :stock), scope.store} do
      {:error, _store} ->
        :ok

      # Stock belongs to a store; an admin looking at all stores must pick one.
      {{:ok, _stock}, nil} ->
        {:error, Ecto.Changeset.add_error(changeset, :stock, "pilih toko untuk mengubah stok")}

      {{:ok, stock}, store} ->
        set_stock(store.id, product.id, stock)
    end
  end

  defp set_stock(store_id, product_id, stock) do
    Repo.insert!(%ProductStock{store_id: store_id, product_id: product_id, stock: stock},
      on_conflict: [set: [stock: stock, updated_at: now()]]
    )

    :ok
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

  @doc """
  Updates a product. Changing `stock` sets the stock in the scope's store, so
  `product` must have been loaded with the same scope.
  """
  def update_product(%Scope{} = scope, %Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> save_with_stock(scope, &Repo.update/1)
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

  ## Suppliers (consignors)

  defp suppliers_query, do: from(s in Supplier, where: is_nil(s.deleted_at))

  @doc "Lists all (non-deleted) suppliers ordered by name."
  def list_suppliers do
    suppliers_query() |> order_by(:name) |> Repo.all()
  end

  @doc "Returns `{name, id}` tuples for use in select inputs."
  def supplier_options do
    suppliers_query()
    |> order_by(:name)
    |> select([s], {s.name, s.id})
    |> Repo.all()
  end

  def get_supplier!(id), do: suppliers_query() |> Repo.get!(id)

  @doc """
  Current on-hand consignment stock per product (units still in the shop that
  could be returned to the consignor), valued at the consignment (purchase) price.
  """
  def consignment_stock_on_hand(%Scope{} = scope) do
    Repo.all(
      from [p, stock: st] in products_query(scope),
        join: sup in assoc(p, :supplier),
        where: p.consignment == true and st.stock > 0,
        order_by: [sup.name, p.name],
        select: %{
          supplier_id: sup.id,
          supplier: sup.name,
          product: p.name,
          sku: p.sku,
          units: st.stock,
          cost_value: fragment("? * ?", p.purchase_price, st.stock)
        }
    )
    |> Enum.map(fn row ->
      %{row | units: to_integer(row.units), cost_value: to_decimal(row.cost_value)}
    end)
  end

  # SUM() over all stores comes back as a Decimal.
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n

  def create_supplier(attrs \\ %{}) do
    %Supplier{}
    |> Supplier.changeset(attrs)
    |> Repo.insert()
  end

  def update_supplier(%Supplier{} = supplier, attrs) do
    supplier
    |> Supplier.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft-deletes a supplier (sets `deleted_at`); the row is kept for history."
  def delete_supplier(%Supplier{} = supplier) do
    supplier
    |> Ecto.Changeset.change(deleted_at: now())
    |> Repo.update()
  end

  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
