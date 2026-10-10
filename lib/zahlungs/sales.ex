defmodule Zahlungs.Sales do
  @moduledoc """
  The Sales context: cashier transactions.

  `create_sale/3` is the heart of the POS — it records a sale and its line items
  and decrements product stock atomically inside a single transaction, refusing
  to oversell.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Zahlungs.LocalTime
  alias Zahlungs.Repo

  alias Zahlungs.Accounts.User
  alias Zahlungs.Catalog.{Product, ProductStock}
  alias Zahlungs.Sales.{Sale, SaleItem}
  alias Zahlungs.Scope
  alias Zahlungs.Shifts
  alias Zahlungs.Stores

  @doc """
  Records a sale from a cart.

    * `user` - the cashier (`%Accounts.User{}`)
    * `cart` - list of `%{product_id: id, quantity: qty}`
    * `payment` - map with `:amount_paid`, `:discount`, `:tax` (strings/numbers/Decimal)

  Returns `{:ok, sale}` (preloaded with items + products) or one of:
  `{:error, :empty_cart}`, `{:error, :invalid_discount}` (negative or above
  the subtotal), `{:error, :invalid_tax}` (negative),
  `{:error, :insufficient_payment}`, `{:error, :no_open_shift}`, `{:error, {:insufficient_stock, product_name}}`.

  The sale is recorded on the cashier's open shift, which is looked up and
  locked here (never taken from the caller), so a sale can't land on a closed
  shift or on none at all. The shift also decides the **store**: the sale
  belongs to the shift's store and takes its stock from there.

  Stock is decremented with a guarded `UPDATE ... WHERE stock >= qty`, so the
  whole transaction rolls back (no sale, no stock change) if any item would
  oversell.
  """
  def create_sale(user, cart, payment \\ %{})

  def create_sale(_user, [], _payment), do: {:error, :empty_cart}

  def create_sale(user, cart, payment) do
    with [_ | _] = items <- build_items(cart),
         {:ok, totals} <- compute_totals(items, payment) do
      do_create_sale(user, items, totals)
    else
      [] -> {:error, :empty_cart}
      {:error, reason} -> {:error, reason}
    end
  end

  # Works out the money side of a sale and rejects amounts that make no sense:
  # a discount must be between 0 and the subtotal (a negative one would silently
  # raise the price), and tax can't be negative.
  defp compute_totals(items, payment) do
    discount = to_decimal(payment[:discount] || payment["discount"])
    tax = to_decimal(payment[:tax] || payment["tax"])
    subtotal = Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.line_total))

    cond do
      Decimal.negative?(discount) or Decimal.gt?(discount, subtotal) ->
        {:error, :invalid_discount}

      Decimal.negative?(tax) ->
        {:error, :invalid_tax}

      true ->
        total = subtotal |> Decimal.sub(discount) |> Decimal.add(tax)
        settle(payment, %{subtotal: subtotal, discount: discount, tax: tax, total: total})
    end
  end

  # Non-cash payments (QRIS/card/transfer) are settled for the exact total, so
  # there is no tendered amount to validate and no change to give. Only cash
  # payments must cover the total and can produce change.
  defp settle(payment, %{total: total} = totals) do
    payment_method = payment[:payment_method] || payment["payment_method"] || "cash"
    totals = Map.put(totals, :payment_method, payment_method)

    if payment_method == "cash" do
      amount_paid = to_decimal(payment[:amount_paid] || payment["amount_paid"])

      if Decimal.lt?(amount_paid, total),
        do: {:error, :insufficient_payment},
        else:
          {:ok,
           Map.merge(totals, %{
             amount_paid: amount_paid,
             change_due: Decimal.sub(amount_paid, total)
           })}
    else
      {:ok, Map.merge(totals, %{amount_paid: total, change_due: Decimal.new(0)})}
    end
  end

  defp do_create_sale(user, items, totals) do
    sale_attrs = Map.merge(totals, %{user_id: user.id, status: "completed"})

    Multi.new()
    |> Multi.run(:shift, fn _repo, _changes -> Shifts.lock_current_shift(user) end)
    |> Multi.run(:store, fn _repo, %{shift: shift} -> {:ok, Stores.get_store!(shift.store_id)} end)
    |> Multi.insert(:sale, fn %{shift: shift, store: store} ->
      Sale.changeset(
        %Sale{},
        Map.merge(sale_attrs, %{
          shift_id: shift.id,
          store_id: store.id,
          code: generate_code(store)
        })
      )
    end)
    |> insert_items_and_decrement_stock(items)
    |> Repo.transaction()
    |> case do
      {:ok, %{sale: sale}} -> {:ok, Repo.preload(sale, [:user, :store, items: :product])}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Human-readable, collision-resistant invoice code: store code + INV +
  # timestamp (store-local) + random hex.
  defp generate_code(store) do
    ts = Calendar.strftime(LocalTime.now(store), "%y%m%d%H%M%S")
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16()
    "#{store.code}-INV#{ts}#{suffix}"
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
          line_total: item.line_total,
          consignment: item.consignment,
          supplier_id: item.supplier_id
        })
      end)
      |> Multi.run({:stock, item.product_id}, fn repo, %{store: store} ->
        decrement_stock(repo, store.id, item)
      end)
    end)
  end

  # Guarded decrement of the store's stock: only succeeds while enough is left
  # (a store with no stock row for the product has none).
  defp decrement_stock(repo, store_id, item) do
    {count, _} =
      repo.update_all(
        from(ps in ProductStock,
          where:
            ps.store_id == ^store_id and ps.product_id == ^item.product_id and
              ps.stock >= ^item.quantity
        ),
        inc: [stock: -item.quantity]
      )

    if count == 1, do: {:ok, count}, else: {:error, {:insufficient_stock, item.name}}
  end

  # Aggregates duplicate product lines and snapshots the product as it is now
  # (prices, and whether it is a consignment item and whose); drops lines whose
  # product no longer exists or whose quantity is not positive.
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
              line_total: Decimal.mult(product.price, qty),
              consignment: product.consignment,
              supplier_id: if(product.consignment, do: product.supplier_id)
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
  sale is no longer `completed` (already returned or voided).

  The status is re-checked under a row lock, not read from the given struct, so
  two concurrent requests can't both restore the stock.

  ## Where the refunded cash comes from

  While the sale's shift is still open, the sale simply stops counting toward
  that shift's expected cash. Once that shift is closed its figures are final,
  so the refund is recorded instead as a `refund` cash-out on the open shift of
  `refunded_by` (the user handing the money back), if they have one. Non-cash
  sales never touch a drawer.
  """
  def return_sale(%Sale{} = sale, refunded_by \\ nil) do
    sale = Repo.preload(sale, :items)

    Multi.new()
    |> Multi.run(:locked, fn _repo, _changes -> lock_completed(sale, :already_returned) end)
    |> Multi.run(:shift, fn _repo, %{locked: locked} -> {:ok, lock_sale_shift(locked)} end)
    |> Multi.run(:refund, fn _repo, %{locked: locked, shift: shift} ->
      record_refund(locked, shift, refunded_by)
    end)
    |> Multi.update(:sale, fn %{shift: shift} ->
      Sale.return_changeset(sale, shift_closed?(shift))
    end)
    |> restore_stock(sale)
    |> Repo.transaction()
    |> case do
      {:ok, %{sale: returned}} -> {:ok, returned}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Voids a completed sale to correct a cashier input error: restores stock and
  marks the sale `void` with a reason and the acting user, atomically.

  A cashier may only void a sale whose shift is still open; once the shift is
  closed, voiding requires an admin. Returns:

    * `{:error, :not_voidable}` - the sale is not in `completed` status
    * `{:error, :shift_closed}` - shift already closed and the user isn't admin
  """
  def void_sale(%Sale{} = sale, %User{} = user, reason) do
    sale = Repo.preload(sale, :items)

    Multi.new()
    |> Multi.run(:locked, fn _repo, _changes -> lock_completed(sale, :not_voidable) end)
    |> Multi.run(:shift, fn _repo, %{locked: locked} -> check_shift_allows_void(locked, user) end)
    |> Multi.update(:sale, fn %{shift: shift} ->
      Sale.void_changeset(sale, user.id, reason, shift_closed?(shift))
    end)
    |> restore_stock(sale)
    |> Repo.transaction()
    |> case do
      {:ok, %{sale: voided}} -> {:ok, voided}
      {:error, _step, err, _changes} -> {:error, err}
    end
  end

  # Locks the sale row and confirms it is still `completed` in the database. The
  # struct a caller holds may be stale (another tab, a double click), and acting
  # on it would restore the stock twice.
  defp lock_completed(%Sale{id: id}, error) do
    case Repo.one(from s in Sale, where: s.id == ^id, lock: "FOR UPDATE") do
      %Sale{status: "completed"} = locked -> {:ok, locked}
      _ -> {:error, error}
    end
  end

  # The sale's shift is locked too, so a return or void can't slip in while the
  # shift is being closed and leave its expected cash out of date.
  defp lock_sale_shift(%Sale{shift_id: nil}), do: nil
  defp lock_sale_shift(%Sale{shift_id: shift_id}), do: Shifts.lock_shift(shift_id)

  defp shift_closed?(shift), do: not is_nil(shift) and shift.status == "closed"

  defp check_shift_allows_void(%Sale{} = sale, %User{} = user) do
    shift = lock_sale_shift(sale)

    if shift_closed?(shift) and user.role != "admin",
      do: {:error, :shift_closed},
      else: {:ok, shift}
  end

  # Cash handed back for a sale whose shift is no longer open (closed, or a sale
  # from before shifts existed) leaves the drawer of whoever processes the
  # return, so it is booked there as a cash-out.
  defp record_refund(%Sale{payment_method: "cash"} = sale, shift, %User{} = refunded_by) do
    with true <- (is_nil(shift) or shift_closed?(shift)) and Decimal.gt?(sale.total, 0),
         {:ok, drawer} <- Shifts.lock_current_shift(refunded_by) do
      Shifts.add_cash_movement(drawer, %{
        "category" => "refund",
        "amount" => sale.total,
        "note" => "Refund #{sale.code}"
      })
    else
      _ -> {:ok, nil}
    end
  end

  defp record_refund(%Sale{}, _shift, _refunded_by), do: {:ok, nil}

  # Puts the items back into the stock of the store that sold them — not the
  # store of whoever processes the return.
  defp restore_stock(multi, %Sale{store_id: store_id, items: items}) do
    Enum.reduce(items, multi, fn item, multi ->
      if item.product_id do
        Multi.insert(
          multi,
          {:restore, item.id},
          %ProductStock{store_id: store_id, product_id: item.product_id, stock: item.quantity},
          on_conflict: [inc: [stock: item.quantity]]
        )
      else
        multi
      end
    end)
  end

  ## Queries
  #
  # Everything below is read through a scope: a cashier sees their store's
  # sales, an admin the store they picked or all of them.

  defp for_store(query, scope) do
    case Scope.store_id(scope) do
      nil -> query
      store_id -> where(query, [s], s.store_id == ^store_id)
    end
  end

  @doc """
  Lists recent sales (most recent first), preloading the cashier and items.

  ## Options
    * `:limit` - max rows (default 50)
    * `:offset` - rows to skip, for paging (default 0)
    * `:date` - a `%Date{}` to restrict to sales recorded on that (shop-local) day
  """
  def list_sales(%Scope{} = scope, opts \\ []) do
    limit = opts[:limit] || 50
    offset = opts[:offset] || 0

    Sale
    |> for_store(scope)
    |> filter_on_date(opts[:date], scope)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> offset(^offset)
    |> preload([:user, :store, :items])
    |> Repo.all()
  end

  @doc "Counts sales matching the same `:date` filter as `list_sales/2`."
  def count_sales(%Scope{} = scope, opts \\ []) do
    Sale
    |> for_store(scope)
    |> filter_on_date(opts[:date], scope)
    |> Repo.aggregate(:count)
  end

  defp filter_on_date(query, nil, _scope), do: query

  defp filter_on_date(query, %Date{} = date, scope) do
    {start, finish} = LocalTime.day_range(date, date, scope.store)
    where(query, [s], s.inserted_at >= ^start and s.inserted_at <= ^finish)
  end

  @doc """
  Gets a sale with its items (and their products), cashier and store. Raises
  `Ecto.NoResultsError` if it belongs to another store than the scope's.
  """
  def get_sale!(%Scope{} = scope, id) do
    Sale
    |> for_store(scope)
    |> Repo.get!(id)
    |> Repo.preload([:user, :store, items: :product])
  end

  @doc "Returns `%{count: integer, total: Decimal}` for sales recorded today (shop-local)."
  def sales_summary_today(%Scope{} = scope) do
    today = LocalTime.today(scope.store)
    query = completed_sales(scope, today, today)

    %{
      count: Repo.aggregate(query, :count),
      total: Repo.aggregate(query, :sum, :total) || Decimal.new(0)
    }
  end

  ## Reporting

  # Completed sales of the scope's store(s) within the inclusive range of
  # shop-local dates. With a store, days start and end on that store's clock;
  # across all stores, on the default one (see Zahlungs.LocalTime).
  defp completed_sales(scope, %Date{} = date_from, %Date{} = date_to) do
    {start, finish} = LocalTime.day_range(date_from, date_to, scope.store)

    from s in for_store(Sale, scope),
      where: s.status == "completed" and s.inserted_at >= ^start and s.inserted_at <= ^finish
  end

  @doc """
  Sales report metrics for the inclusive date range (completed sales only).

  Returns a map with: `:transactions`, `:items_sold`, `:revenue` (net total after
  discount/tax), `:discount`, `:tax`, `:gross_sales` (sum of line totals),
  `:cogs` (cost of goods sold from the purchase-price snapshot), `:gross_profit`.
  """
  def sales_report(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    sales = completed_sales(scope, date_from, date_to)

    totals =
      Repo.one(
        from s in sales,
          select: %{
            transactions: count(s.id),
            revenue: coalesce(sum(s.total), 0),
            discount: coalesce(sum(s.discount), 0),
            tax: coalesce(sum(s.tax), 0)
          }
      )

    items =
      Repo.one(
        from s in sales,
          join: i in assoc(s, :items),
          select: %{
            items_sold: coalesce(sum(i.quantity), 0),
            gross_sales: coalesce(sum(i.line_total), 0),
            cogs: coalesce(sum(fragment("? * ?", i.purchase_price, i.quantity)), 0)
          }
      )

    gross_sales = to_decimal(items.gross_sales)
    cogs = to_decimal(items.cogs)

    %{
      transactions: totals.transactions,
      items_sold: items.items_sold,
      revenue: to_decimal(totals.revenue),
      discount: to_decimal(totals.discount),
      tax: to_decimal(totals.tax),
      gross_sales: gross_sales,
      cogs: cogs,
      gross_profit: Decimal.sub(gross_sales, cogs)
    }
  end

  @doc "Top-selling products by quantity for the date range (completed sales)."
  def top_products(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to, limit \\ 10) do
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        join: i in assoc(s, :items),
        left_join: p in assoc(i, :product),
        group_by: [i.product_id, p.name],
        order_by: [desc: sum(i.quantity)],
        limit: ^limit,
        select: %{
          name: p.name,
          quantity: coalesce(sum(i.quantity), 0),
          revenue: coalesce(sum(i.line_total), 0)
        }
    )
  end

  @doc "Per-category breakdown (completed sales) for the date range: category, quantity, revenue."
  def sales_by_category(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        join: i in assoc(s, :items),
        left_join: p in assoc(i, :product),
        left_join: c in assoc(p, :category),
        group_by: c.name,
        order_by: [desc: sum(i.line_total)],
        select: %{
          category: c.name,
          quantity: coalesce(sum(i.quantity), 0),
          revenue: coalesce(sum(i.line_total), 0)
        }
    )
  end

  @doc """
  Consignment settlement per supplier for the date range (completed sales only,
  consignment items only). For each supplier returns the quantity sold, the
  revenue, the amount payable to the supplier (Σ snapshot purchase_price × qty),
  and the shop's margin (revenue − payable).

  Whether an item is consignment, and for which supplier, comes from the
  snapshot taken when it was sold, so later changes to the product don't alter
  past periods.
  """
  def consignment_settlement(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        join: i in assoc(s, :items),
        join: sup in assoc(i, :supplier),
        where: i.consignment == true,
        group_by: [sup.id, sup.name],
        order_by: [desc: sum(i.line_total)],
        select: %{
          supplier_id: sup.id,
          supplier: sup.name,
          qty_sold: coalesce(sum(i.quantity), 0),
          revenue: coalesce(sum(i.line_total), 0),
          payable: coalesce(sum(fragment("? * ?", i.purchase_price, i.quantity)), 0)
        }
    )
    |> Enum.map(fn row ->
      revenue = to_decimal(row.revenue)
      payable = to_decimal(row.payable)

      %{row | revenue: revenue, payable: payable, qty_sold: to_int(row.qty_sold)}
      |> Map.put(:margin, Decimal.sub(revenue, payable))
    end)
  end

  @doc """
  Consignment statement per supplier: what was sold and paid within the date
  range, plus the balance still owed as of `date_to`.

  Each row has the period figures of `consignment_settlement/3` (`:qty_sold`,
  `:revenue`, `:payable`, `:margin`), `:paid` (payments made in the range) and
  `:outstanding`. The outstanding balance is cumulative — everything payable up
  to `date_to` minus everything paid up to `date_to` — because a payment rarely
  falls in the same period as the sales it settles. Suppliers with no activity
  in the range are still listed while a balance remains.

  With a store in the scope, only that store's sales and payments count; an
  admin looking at all stores gets the supplier's balance across them.
  """
  def consignment_statement(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    period = Map.new(consignment_settlement(scope, date_from, date_to), &{&1.supplier_id, &1})
    paid_in_period = Shifts.consignment_payments_by_supplier(scope, date_from, date_to)
    payable_to_date = consignment_payable_to_date(scope, date_to)
    paid_to_date = Shifts.consignment_payments_to_date(scope, date_to)

    zero = Decimal.new(0)

    payable_to_date
    |> Map.merge(paid_to_date, fn _id, payable, paid -> Map.merge(paid, payable) end)
    |> Enum.map(fn {supplier_id, to_date} ->
      sold =
        Map.get(period, supplier_id, %{qty_sold: 0, revenue: zero, payable: zero, margin: zero})

      %{
        supplier_id: supplier_id,
        supplier: to_date.supplier,
        qty_sold: sold.qty_sold,
        revenue: sold.revenue,
        payable: sold.payable,
        margin: sold.margin,
        paid: Map.get(paid_in_period, supplier_id, zero),
        outstanding: Decimal.sub(Map.get(to_date, :payable, zero), Map.get(to_date, :paid, zero))
      }
    end)
    |> Enum.filter(fn row ->
      row.qty_sold > 0 or not Decimal.equal?(row.paid, zero) or
        not Decimal.equal?(row.outstanding, zero)
    end)
    |> Enum.sort_by(&{Decimal.to_float(Decimal.negate(&1.outstanding)), &1.supplier})
  end

  # Everything payable to each supplier for consignment items sold up to (and
  # including) `date_to`, as `%{supplier_id => %{supplier: name, payable: Decimal}}`.
  defp consignment_payable_to_date(scope, %Date{} = date_to) do
    {_start, finish} = LocalTime.day_range(date_to, date_to, scope.store)

    Repo.all(
      from s in for_store(Sale, scope),
        join: i in assoc(s, :items),
        join: sup in assoc(i, :supplier),
        where: s.status == "completed" and i.consignment == true and s.inserted_at <= ^finish,
        group_by: [sup.id, sup.name],
        select:
          {sup.id,
           %{
             supplier: sup.name,
             payable: coalesce(sum(fragment("? * ?", i.purchase_price, i.quantity)), 0)
           }}
    )
    |> Map.new(fn {id, row} -> {id, %{row | payable: to_decimal(row.payable)}} end)
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n

  @doc "Daily breakdown (completed sales) for the date range: date, transactions, revenue."
  def sales_by_day(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    offset = LocalTime.offset_seconds(scope.store)

    # Group on the shop-local calendar day, not the UTC one.
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        group_by: selected_as(:day),
        order_by: selected_as(:day),
        select: %{
          date:
            selected_as(
              fragment("DATE(DATE_ADD(?, INTERVAL ? SECOND))", s.inserted_at, ^offset),
              :day
            ),
          transactions: count(s.id),
          revenue: coalesce(sum(s.total), 0)
        }
    )
  end

  @doc "Per-cashier breakdown (completed sales) for the date range: cashier, transactions, revenue."
  def sales_by_cashier(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        left_join: u in assoc(s, :user),
        group_by: [s.user_id, u.email],
        order_by: [desc: sum(s.total)],
        select: %{
          cashier: u.email,
          transactions: count(s.id),
          revenue: coalesce(sum(s.total), 0)
        }
    )
  end

  @doc "Per-store breakdown (completed sales) for the date range: store, transactions, revenue."
  def sales_by_store(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    Repo.all(
      from s in completed_sales(scope, date_from, date_to),
        join: st in assoc(s, :store),
        group_by: [st.id, st.name],
        order_by: [desc: sum(s.total)],
        select: %{
          store: st.name,
          transactions: count(s.id),
          revenue: coalesce(sum(s.total), 0)
        }
    )
  end

  ## Helpers

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  # Anything that isn't a finite number ("abc", "NaN", "Infinity") counts as 0.
  defp to_decimal(s) when is_binary(s) do
    case s |> String.trim() |> Decimal.parse() do
      {%Decimal{coef: coef} = d, _} when is_integer(coef) -> d
      _ -> Decimal.new(0)
    end
  end
end
