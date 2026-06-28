defmodule Zahlungs.Sales do
  @moduledoc """
  The Sales context: cashier transactions.

  `create_sale/3` is the heart of the POS — it records a sale and its line items
  and decrements product stock atomically inside a single transaction, refusing
  to oversell.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Zahlungs.Repo

  alias Zahlungs.Catalog.Product
  alias Zahlungs.Sales.{Sale, SaleItem}

  @doc """
  Records a sale from a cart.

    * `user` - the cashier (`%Accounts.User{}`)
    * `cart` - list of `%{product_id: id, quantity: qty}`
    * `payment` - map with `:amount_paid`, `:discount`, `:tax` (strings/numbers/Decimal)

  Returns `{:ok, sale}` (preloaded with items + products) or one of:
  `{:error, :empty_cart}`, `{:error, :insufficient_payment}`,
  `{:error, {:insufficient_stock, product_name}}`.

  Stock is decremented with a guarded `UPDATE ... WHERE stock >= qty`, so the
  whole transaction rolls back (no sale, no stock change) if any item would
  oversell.
  """
  def create_sale(user, cart, payment \\ %{})

  def create_sale(_user, [], _payment), do: {:error, :empty_cart}

  def create_sale(user, cart, payment) do
    discount = to_decimal(payment[:discount] || payment["discount"])
    tax = to_decimal(payment[:tax] || payment["tax"])
    amount_paid = to_decimal(payment[:amount_paid] || payment["amount_paid"])

    items = build_items(cart)

    cond do
      items == [] ->
        {:error, :empty_cart}

      true ->
        subtotal = Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.line_total))
        total = subtotal |> Decimal.sub(discount) |> Decimal.add(tax)
        change_due = Decimal.sub(amount_paid, total)

        if Decimal.lt?(amount_paid, total) do
          {:error, :insufficient_payment}
        else
          do_create_sale(user, items, %{
            subtotal: subtotal,
            discount: discount,
            tax: tax,
            total: total,
            amount_paid: amount_paid,
            change_due: change_due
          })
        end
    end
  end

  defp do_create_sale(user, items, totals) do
    sale_attrs =
      Map.merge(totals, %{user_id: user.id, status: "completed", code: generate_code()})

    Multi.new()
    |> Multi.insert(:sale, Sale.changeset(%Sale{}, sale_attrs))
    |> insert_items_and_decrement_stock(items)
    |> Repo.transaction()
    |> case do
      {:ok, %{sale: sale}} -> {:ok, Repo.preload(sale, [:user, items: :product])}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Human-readable, collision-resistant invoice code: INV + timestamp + random hex.
  defp generate_code do
    ts = Calendar.strftime(DateTime.utc_now(), "%y%m%d%H%M%S")
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16()
    "INV#{ts}#{suffix}"
  end

  defp insert_items_and_decrement_stock(multi, items) do
    Enum.reduce(items, multi, fn item, multi ->
      multi
      |> Multi.insert({:item, item.product_id}, fn %{sale: sale} ->
        SaleItem.changeset(%SaleItem{}, %{
          sale_id: sale.id,
          product_id: item.product_id,
          quantity: item.quantity,
          unit_price: item.unit_price,
          purchase_price: item.purchase_price,
          line_total: item.line_total
        })
      end)
      |> Multi.run({:stock, item.product_id}, fn repo, _changes ->
        {count, _} =
          repo.update_all(
            from(p in Product, where: p.id == ^item.product_id and p.stock >= ^item.quantity),
            inc: [stock: -item.quantity]
          )

        if count == 1, do: {:ok, count}, else: {:error, {:insufficient_stock, item.name}}
      end)
    end)
  end

  # Aggregates duplicate product lines and snapshots current price; drops lines
  # whose product no longer exists or whose quantity is not positive.
  defp build_items(cart) do
    aggregated =
      Enum.reduce(cart, %{}, fn %{product_id: pid, quantity: qty}, acc ->
        Map.update(acc, pid, qty, &(&1 + qty))
      end)

    product_ids = Map.keys(aggregated)
    products = Repo.all(from p in Product, where: p.id in ^product_ids) |> Map.new(&{&1.id, &1})

    aggregated
    |> Enum.flat_map(fn {pid, qty} ->
      case products[pid] do
        %Product{} = product when qty > 0 ->
          [
            %{
              product_id: pid,
              name: product.name,
              quantity: qty,
              unit_price: product.price,
              purchase_price: product.purchase_price,
              line_total: Decimal.mult(product.price, qty)
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  Returns/refunds a completed sale: restores stock for each item and marks the
  sale as `returned`, atomically. Returns `{:error, :already_returned}` if the
  sale was already returned.
  """
  def return_sale(%Sale{status: "completed"} = sale) do
    sale = Repo.preload(sale, :items)

    Multi.new()
    |> Multi.update(:sale, Sale.return_changeset(sale))
    |> restore_stock(sale.items)
    |> Repo.transaction()
    |> case do
      {:ok, %{sale: returned}} -> {:ok, returned}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def return_sale(%Sale{}), do: {:error, :already_returned}

  defp restore_stock(multi, items) do
    Enum.reduce(items, multi, fn item, multi ->
      if item.product_id do
        Multi.update_all(
          multi,
          {:restore, item.id},
          from(p in Product, where: p.id == ^item.product_id),
          inc: [stock: item.quantity]
        )
      else
        multi
      end
    end)
  end

  ## Queries

  @doc """
  Lists recent sales (most recent first), preloading the cashier and items.

  ## Options
    * `:limit` - max rows (default 50)
    * `:date` - a `%Date{}` to restrict to sales recorded on that day
  """
  def list_sales(opts \\ []) do
    limit = opts[:limit] || 50

    Sale
    |> filter_on_date(opts[:date])
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload([:user, :items])
    |> Repo.all()
  end

  defp filter_on_date(query, nil), do: query

  defp filter_on_date(query, %Date{} = date) do
    start = NaiveDateTime.new!(date, ~T[00:00:00])
    finish = NaiveDateTime.new!(date, ~T[23:59:59])
    where(query, [s], s.inserted_at >= ^start and s.inserted_at <= ^finish)
  end

  @doc "Gets a sale with its items (and their products) and cashier."
  def get_sale!(id) do
    Sale
    |> Repo.get!(id)
    |> Repo.preload([:user, items: :product])
  end

  @doc "Returns `%{count: integer, total: Decimal}` for sales recorded today (UTC)."
  def sales_summary_today do
    start = NaiveDateTime.new!(Date.utc_today(), ~T[00:00:00])

    query = from s in Sale, where: s.inserted_at >= ^start and s.status == "completed"

    %{
      count: Repo.aggregate(query, :count),
      total: Repo.aggregate(query, :sum, :total) || Decimal.new(0)
    }
  end

  ## Helpers

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case s |> String.trim() |> Decimal.parse() do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end
end
