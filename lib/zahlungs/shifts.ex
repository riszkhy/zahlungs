defmodule Zahlungs.Shifts do
  @moduledoc """
  The Shifts context: cashier work sessions (buka/tutup kas).

  A shift starts with an opening cash float, tags the sales made during it, and
  on close reconciles the expected cash against the counted (physical) cash to
  produce a variance.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Accounts.User
  alias Zahlungs.Scope
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Shifts.{Shift, CashMovement}

  @doc "Returns the user's currently open shift, or nil."
  def current_shift(%User{} = user) do
    Repo.one(from s in Shift, where: s.user_id == ^user.id and s.status == "open", limit: 1)
  end

  @doc """
  Opens a shift for the scope's user in the scope's store, with the given
  opening cash float. Returns `{:error, :already_open}` if the user already has
  an open shift (in any store), or `{:error, :no_store}` for an admin who is
  looking at all stores and so has no drawer to open.

  The user row is locked for the duration, so two concurrent calls for the same
  user can't both pass the "no open shift" check.
  """
  def open_shift(%Scope{store: nil}, _opening_cash), do: {:error, :no_store}

  def open_shift(%Scope{user: %User{} = user, store: store}, opening_cash) do
    Repo.transaction(fn ->
      Repo.one!(from u in User, where: u.id == ^user.id, select: u.id, lock: "FOR UPDATE")

      if current_shift(user) do
        Repo.rollback(:already_open)
      else
        %Shift{}
        |> Shift.open_changeset(%{
          user_id: user.id,
          store_id: store.id,
          opening_cash: to_decimal(opening_cash),
          opened_at: now(),
          status: "open"
        })
        |> Repo.insert()
        |> unwrap_or_rollback()
      end
    end)
  end

  @doc """
  Closes an open shift: computes expected cash and variance vs the counted cash.
  Returns `{:error, :not_open}` if the shift is already closed, and
  `{:error, :services_processing}` while a service of the shift is still
  processing.

  The shift row is locked first, so the expected cash includes every sale and
  cash movement recorded on the shift and none can be added afterwards.
  """
  def close_shift(%Shift{} = shift, counted_cash, note \\ nil) do
    Repo.transaction(fn ->
      with_open_shift(shift, fn ->
        refuse_while_services_processing(shift)
        expected = expected_cash(shift)
        counted = to_decimal(counted_cash)

        shift
        |> Shift.close_changeset(%{
          status: "closed",
          closed_at: now(),
          expected_cash: expected,
          counted_cash: counted,
          variance: Decimal.sub(counted, expected),
          note: note
        })
        |> Repo.update()
        |> unwrap_or_rollback()
      end)
    end)
  end

  @doc """
  Records a cash movement (drawer in/out) against an open shift. The shift and
  user are taken from the shift itself (never from `attrs`, so they can't be
  spoofed). Returns `{:error, :not_open}` for a closed shift.
  """
  def add_cash_movement(%Shift{} = shift, attrs \\ %{}) do
    Repo.transaction(fn ->
      with_open_shift(shift, fn ->
        %CashMovement{shift_id: shift.id, user_id: shift.user_id}
        |> CashMovement.changeset(attrs)
        |> Repo.insert()
        |> unwrap_or_rollback()
      end)
    end)
  end

  @doc """
  Fetches a shift by id with a row lock (`FOR UPDATE`), or nil. Must be called
  inside a transaction; the lock is held until it ends. The returned struct
  reflects the committed state, so its `status` can be trusted — unlike a struct
  loaded earlier (e.g. held in a LiveView's assigns).
  """
  def lock_shift(id) do
    Repo.one(from s in Shift, where: s.id == ^id, lock: "FOR UPDATE")
  end

  @doc """
  Locks and returns the user's open shift, for recording a sale on it. Must be
  called inside a transaction. Returns `{:ok, shift}` or
  `{:error, :no_open_shift}`.
  """
  def lock_current_shift(%User{} = user) do
    with %Shift{id: id} <- current_shift(user),
         %Shift{status: "open"} = shift <- lock_shift(id) do
      {:ok, shift}
    else
      _ -> {:error, :no_open_shift}
    end
  end

  # A service still processing may yet be handed back: its result decides what
  # the drawer should hold. Called under the shift's lock.
  defp refuse_while_services_processing(shift) do
    if Zahlungs.Services.count_processing(shift) > 0, do: Repo.rollback(:services_processing)
  end

  # Runs `fun` only if the shift is still open in the database (not just in the
  # possibly stale struct), holding its row lock.
  defp with_open_shift(%Shift{id: id}, fun) do
    case lock_shift(id) do
      %Shift{status: "open"} -> fun.()
      _ -> Repo.rollback(:not_open)
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  @doc """
  Total consignment payments (cash-out) per supplier within the date range,
  as a map `%{supplier_id => Decimal}`. Used by the settlement report to show
  how much has already been paid vs the payable amount. Limited to payments
  made from the scope's store.
  """
  def consignment_payments_by_supplier(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    {start, finish} = Zahlungs.LocalTime.day_range(date_from, date_to, scope.store)

    Repo.all(
      from m in movements_query(scope),
        where:
          m.category == "consignment_payment" and not is_nil(m.supplier_id) and
            m.inserted_at >= ^start and m.inserted_at <= ^finish,
        group_by: m.supplier_id,
        select: {m.supplier_id, coalesce(sum(m.amount), 0)}
    )
    |> Map.new(fn {sid, total} -> {sid, to_decimal(total)} end)
  end

  @doc """
  Everything paid to each supplier up to (and including) `date_to`, as
  `%{supplier_id => %{supplier: name, paid: Decimal}}`. Used for the balance
  still owed to a supplier as of a date.
  """
  def consignment_payments_to_date(%Scope{} = scope, %Date{} = date_to) do
    {_start, finish} = Zahlungs.LocalTime.day_range(date_to, date_to, scope.store)

    Repo.all(
      from m in movements_query(scope),
        join: sup in assoc(m, :supplier),
        where: m.category == "consignment_payment" and m.inserted_at <= ^finish,
        group_by: [sup.id, sup.name],
        select: {sup.id, %{supplier: sup.name, paid: coalesce(sum(m.amount), 0)}}
    )
    |> Map.new(fn {id, row} -> {id, %{row | paid: to_decimal(row.paid)}} end)
  end

  # Cash movements made in the scope's store (a movement's store is its shift's).
  defp movements_query(scope) do
    store_ids =
      case Scope.store_id(scope) do
        nil -> Zahlungs.Stores.store_ids()
        store_id -> [store_id]
      end

    from m in CashMovement,
      join: sh in assoc(m, :shift),
      where: sh.store_id in ^store_ids
  end

  @doc "Lists the cash movements of a shift (most recent first), preloading supplier."
  def list_cash_movements(%Shift{} = shift) do
    Repo.all(
      from m in CashMovement,
        where: m.shift_id == ^shift.id,
        order_by: [desc: m.inserted_at],
        preload: [:supplier]
    )
  end

  @doc """
  Expected cash in the drawer for a shift:

      opening float + completed cash sales + cash services + cash-in movements − cash-out movements

  Cash services count while processing or successful (see
  `Zahlungs.Services.shift_totals/1`).

  Non-cash sales (QRIS/card/transfer) never enter the drawer, so they are
  excluded. Cash movements (setoran, pengeluaran, bayar konsinyasi, refund)
  adjust the expected amount.

  A sale returned or voided while the shift is open stops counting. One
  returned or voided after the shift was closed keeps counting here — the
  closed shift's figures are final — and a refund is booked on the shift that
  actually pays it out (see `Zahlungs.Sales.return_sale/2`).
  """
  def expected_cash(%Shift{} = shift) do
    %{cash_in: cash_in, cash_out: cash_out} = movement_totals(shift.id)

    to_decimal(shift.opening_cash)
    |> Decimal.add(cash_sales_total(shift.id))
    |> Decimal.add(Zahlungs.Services.shift_totals(shift).cash_total)
    |> Decimal.add(cash_in)
    |> Decimal.sub(cash_out)
  end

  @doc """
  Summary for the close/detail screen: opening float, transaction count, cash vs
  non-cash sales totals, cash-in/out movements, and the expected drawer cash
  (opening + cash sales + cash-in − cash-out).
  """
  def shift_summary(%Shift{} = shift) do
    row =
      Repo.one(
        from s in counted_sales(shift.id),
          select: %{
            transactions: count(s.id),
            sales_total: coalesce(sum(s.total), 0),
            cash_total:
              coalesce(
                sum(
                  fragment("CASE WHEN ? = 'cash' THEN ? ELSE 0 END", s.payment_method, s.total)
                ),
                0
              )
          }
      )

    sales_total = to_decimal(row.sales_total)
    cash_total = to_decimal(row.cash_total)
    noncash_total = Decimal.sub(sales_total, cash_total)
    opening = to_decimal(shift.opening_cash)
    %{cash_in: cash_in, cash_out: cash_out} = movement_totals(shift.id)
    services = Zahlungs.Services.shift_totals(shift)

    %{
      opening_cash: opening,
      transactions: row.transactions,
      sales_total: sales_total,
      cash_total: cash_total,
      noncash_total: noncash_total,
      cash_in: cash_in,
      cash_out: cash_out,
      service_count: services.count,
      service_total: services.total,
      service_cash_total: services.cash_total,
      expected_cash:
        opening
        |> Decimal.add(cash_total)
        |> Decimal.add(services.cash_total)
        |> Decimal.add(cash_in)
        |> Decimal.sub(cash_out)
    }
  end

  # The sales that count toward a shift's figures: completed ones, plus those
  # returned or voided only after the shift had been closed.
  defp counted_sales(shift_id) do
    from s in Sale,
      where:
        s.shift_id == ^shift_id and
          (s.status == "completed" or s.adjusted_after_shift_close == true)
  end

  # Total of the cash sales that count toward the shift.
  defp cash_sales_total(shift_id) do
    Repo.one(
      from s in counted_sales(shift_id),
        where: s.payment_method == "cash",
        select: coalesce(sum(s.total), 0)
    )
    |> to_decimal()
  end

  # Cash-in and cash-out movement totals for the shift.
  defp movement_totals(shift_id) do
    row =
      Repo.one(
        from m in CashMovement,
          where: m.shift_id == ^shift_id,
          select: %{
            cash_in:
              coalesce(
                sum(fragment("CASE WHEN ? = 'in' THEN ? ELSE 0 END", m.direction, m.amount)),
                0
              ),
            cash_out:
              coalesce(
                sum(fragment("CASE WHEN ? = 'out' THEN ? ELSE 0 END", m.direction, m.amount)),
                0
              )
          }
      )

    %{cash_in: to_decimal(row.cash_in), cash_out: to_decimal(row.cash_out)}
  end

  @doc """
  Lists the shifts of the scope's store (most recent first), preloading the
  cashier and store.

  Options: `:limit` (default 50), `:user_id` (restrict to one cashier).
  """
  def list_shifts(%Scope{} = scope, opts \\ []) do
    limit = opts[:limit] || 50

    Shift
    |> for_store(scope)
    |> maybe_filter_user(opts[:user_id])
    |> order_by(desc: :opened_at, desc: :id)
    |> limit(^limit)
    |> preload([:user, :store])
    |> Repo.all()
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, user_id), do: where(query, [s], s.user_id == ^user_id)

  # One store, or — for an admin looking at all stores — every store of their
  # organization. Never unfiltered: these tables are shared by all owners.
  defp for_store(query, scope) do
    case Scope.store_id(scope) do
      nil -> where(query, [s], s.store_id in ^Zahlungs.Stores.store_ids())
      store_id -> where(query, [s], s.store_id == ^store_id)
    end
  end

  @doc "Gets a shift of the scope's store (raises if it is another store's)."
  def get_shift!(%Scope{} = scope, id) do
    Shift |> for_store(scope) |> Repo.get!(id) |> Repo.preload([:user, :store])
  end

  @doc "Lists the sales recorded during a shift (most recent first), with items."
  def shift_sales(%Shift{} = shift) do
    Repo.all(
      from s in Sale,
        where: s.shift_id == ^shift.id,
        order_by: [desc: s.inserted_at],
        preload: [:items]
    )
  end

  ## Helpers

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  defp to_decimal(s) when is_binary(s) do
    case s |> String.trim() |> Decimal.parse() do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end
end
