defmodule Zahlungs.Services do
  @moduledoc """
  PPOB services (Fase 0, no provider API): the products a store sells besides
  goods, their price, and the services sold. The cashier does the top-up in
  the provider's own app; Zahlungs records the money and the result.

  ## Price

  `margin(x)` is the product's rupiah margin, or `x × percent / 100` rounded up
  to the whole rupiah.

    * pulsa, paket data, token PLN: cost = the product's cost,
      price = cost + margin(cost).
    * tagihan PLN: cost = bill + provider fee (the product's cost),
      price = bill + margin(bill) — the margin is the admin fee.

  ## Transactions

  A service is recorded when the money is taken (`record/3`, status
  `processing`). The store is the cashier's shift's store and the deposit
  account is that store's; neither comes from the caller.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Accounts.User
  alias Zahlungs.{Deposits, LocalTime, Scope, Shifts, Stores}
  alias Zahlungs.Shifts.Shift
  alias Zahlungs.Services.{Product, Transaction}

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

  ## Recording

  @doc """
  Records a service when the cashier takes the money: status `processing`, on
  the cashier's open shift, in that shift's store, against the store's deposit
  account. The price and cost are worked out here and copied onto the
  transaction.

  `attrs` (string keys): `"customer_ref"`, `"bill_amount"` (tagihan PLN only),
  `"payment_method"` (default `"cash"`) and `"amount_paid"` (cash only).

  Returns `{:ok, transaction}` or `{:error, reason}`: `:no_open_shift`,
  `:no_deposit_account`, `:product_unavailable`, `:bill_required`,
  `:insufficient_payment`, or a changeset (the customer number).
  """
  def record(%User{} = user, product_id, attrs) do
    # The cashier decides whose products and stores these are.
    Repo.put_org_id(user.organization_id)

    Repo.transaction(fn ->
      case insert_transaction(user, product_id, attrs) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Runs inside record/3's transaction: the shift stays locked until it ends.
  defp insert_transaction(user, product_id, attrs) do
    with {:ok, shift} <- Shifts.lock_current_shift(user),
         store = Stores.get_store!(shift.store_id),
         {:ok, account_id} <- store_account(store),
         {:ok, product} <- sellable_product(product_id),
         bill = bill_amount(product, attrs),
         {:ok, %{price: price, cost: cost}} <- price_for(product, bill),
         {:ok, payment} <- settle(attrs, price) do
      %Transaction{
        store_id: store.id,
        shift_id: shift.id,
        user_id: user.id,
        service_product_id: product.id,
        deposit_account_id: account_id,
        code: generate_code(store),
        category: product.category,
        product_name: product.name,
        bill_amount: bill,
        price: price,
        cost: cost,
        amount_paid: payment.amount_paid,
        change_due: payment.change_due
      }
      |> Transaction.record_changeset(%{
        customer_ref: attrs["customer_ref"] || "",
        payment_method: payment.method
      })
      |> Repo.insert()
    end
  end

  ## Results

  @doc """
  Marks a processing service done, with the token or serial number from the
  provider's app (optional). See `mark_failed/3` for who may mark and what is
  refused.
  """
  def mark_success(%Transaction{} = transaction, %User{} = user, token_sn) do
    resolve(transaction, user, %{status: "success", token_sn: token_sn})
  end

  @doc """
  Marks a processing service failed; the reason is required and the money goes
  back to the customer.

  Only the cashier who recorded it, or an admin, may mark a service. The row is
  locked and its status read from the database, so a stale struct (another tab)
  can't mark it a second time. Returns `{:ok, transaction}` or
  `{:error, :forbidden | :not_processing | changeset}`.
  """
  def mark_failed(%Transaction{} = transaction, %User{} = user, reason) do
    resolve(transaction, user, %{status: "failed", failure_reason: reason})
  end

  defp resolve(%Transaction{id: id}, user, attrs) do
    Repo.transaction(fn ->
      locked = Repo.one!(from t in Transaction, where: t.id == ^id, lock: "FOR UPDATE")

      case apply_result(locked, user, attrs) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # `locked` is the row as the database has it, under its lock.
  defp apply_result(locked, user, attrs) do
    cond do
      locked.user_id != user.id and user.role != "admin" ->
        {:error, :forbidden}

      locked.status != "processing" ->
        {:error, :not_processing}

      true ->
        locked
        |> Transaction.resolve_changeset(attrs)
        |> Ecto.Changeset.change(resolved_by_id: user.id, resolved_at: now())
        |> Repo.update()
    end
  end

  ## Reading

  @doc "Gets a service of the scope's store(s); another store's raises `Ecto.NoResultsError`."
  def get_transaction!(%Scope{} = scope, id) do
    Repo.one!(
      from t in for_store(Transaction, scope), where: t.id == ^id, preload: [:store, :user]
    )
  end

  @doc "The services recorded on a shift, newest first."
  def list_shift_transactions(%Shift{id: shift_id}) do
    Repo.all(
      from t in Transaction,
        where: t.shift_id == ^shift_id,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  @doc """
  What a shift's services add up to: `count`, `total` and `cash_total` (the
  cash that went into the drawer). Processing and successful services count —
  the money was taken; failed ones don't — it was handed back.
  """
  def shift_totals(%Shift{id: shift_id}) do
    row =
      Repo.one(
        from t in Transaction,
          where: t.shift_id == ^shift_id and t.status in ["processing", "success"],
          select: %{
            count: count(t.id),
            total: coalesce(sum(t.price), 0),
            cash_total:
              coalesce(
                sum(
                  fragment("CASE WHEN ? = 'cash' THEN ? ELSE 0 END", t.payment_method, t.price)
                ),
                0
              )
          }
      )

    %{count: row.count, total: to_decimal(row.total), cash_total: to_decimal(row.cash_total)}
  end

  @doc """
  What services have taken out of a deposit account: the cost of those
  processing (the provider has charged) and successful. Failed ones are
  refunded by the provider and don't count.
  """
  def deposit_used(%Zahlungs.Deposits.Account{id: account_id}) do
    from(t in Transaction,
      where: t.deposit_account_id == ^account_id and t.status in ["processing", "success"],
      select: coalesce(sum(t.cost), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  ## Report

  @doc """
  The services of the scope's store(s) between two shop-local dates
  (inclusive): how many succeeded and failed, and for the successful ones the
  value (what customers paid), the cost and the margin — in total and per
  category.
  """
  def report(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    {start, finish} = LocalTime.day_range(date_from, date_to, scope.store)

    in_range =
      from t in for_store(Transaction, scope),
        where: t.inserted_at >= ^start and t.inserted_at <= ^finish

    by_category =
      Repo.all(
        from t in in_range,
          where: t.status == "success",
          group_by: t.category,
          order_by: t.category,
          select: %{
            category: t.category,
            count: count(t.id),
            value: coalesce(sum(t.price), 0),
            cost: coalesce(sum(t.cost), 0)
          }
      )
      |> Enum.map(fn row ->
        value = to_decimal(row.value)
        cost = to_decimal(row.cost)
        %{row | value: value, cost: cost} |> Map.put(:margin, Decimal.sub(value, cost))
      end)

    value = sum_of(by_category, :value)
    cost = sum_of(by_category, :cost)

    %{
      success_count: Enum.sum(Enum.map(by_category, & &1.count)),
      failed_count: Repo.aggregate(where(in_range, [t], t.status == "failed"), :count),
      value: value,
      cost: cost,
      margin: Decimal.sub(value, cost),
      by_category: by_category
    }
  end

  defp sum_of(rows, key),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, key)))

  @doc "How many services of a shift are still processing."
  def count_processing(%Shift{id: shift_id}) do
    Repo.aggregate(
      from(t in Transaction, where: t.shift_id == ^shift_id and t.status == "processing"),
      :count
    )
  end

  defp for_store(query, scope) do
    case Scope.store_id(scope) do
      nil -> where(query, [t], t.store_id in ^Stores.store_ids())
      store_id -> where(query, [t], t.store_id == ^store_id)
    end
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

  defp store_account(%{deposit_account_id: id}) do
    if Deposits.active_account?(id), do: {:ok, id}, else: {:error, :no_deposit_account}
  end

  # Active and not deleted: a screen left open may still offer one that isn't.
  defp sellable_product(id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Product{} = product <-
           Repo.one(
             from p in Product,
               where: p.id == ^id and p.active == true and is_nil(p.deleted_at)
           ) do
      {:ok, product}
    else
      _ -> {:error, :product_unavailable}
    end
  end

  defp bill_amount(product, attrs) do
    if Product.bill?(product), do: to_decimal(attrs["bill_amount"])
  end

  # Cash must cover the price and may produce change; other methods are paid
  # for the exact price.
  defp settle(attrs, price) do
    case attrs["payment_method"] do
      method when method in [nil, "", "cash"] ->
        paid = to_decimal(attrs["amount_paid"])

        if Decimal.lt?(paid, price),
          do: {:error, :insufficient_payment},
          else: {:ok, %{method: "cash", amount_paid: paid, change_due: Decimal.sub(paid, price)}}

      method ->
        {:ok, %{method: method, amount_paid: price, change_due: Decimal.new(0)}}
    end
  end

  # Store code + LYN + store-local timestamp + random hex, like a sale's INV code.
  defp generate_code(store) do
    ts = Calendar.strftime(LocalTime.now(store), "%y%m%d%H%M%S")
    "#{store.code}-LYN#{ts}#{Base.encode16(:crypto.strong_rand_bytes(2))}"
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
