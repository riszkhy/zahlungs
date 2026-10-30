defmodule Zahlungs.Customers do
  @moduledoc """
  Piutang (kasbon): customers who take goods now and pay later.

  Customers belong to an organization (one list for every store); a credit
  sale is an ordinary `Zahlungs.Sales.Sale` with `payment_method: "credit"`,
  and repayments are `Zahlungs.Customers.Payment` rows received on a cashier's
  open shift, in any store of the organization.

  Only an admin sets a customer's credit limit; a customer added at the
  cashier starts at 0, i.e. may not buy on credit yet.
  """

  import Ecto.Query, warn: false

  alias Zahlungs.Accounts.User
  alias Zahlungs.Customers.{Customer, Payment}
  alias Zahlungs.{LocalTime, Repo, Shifts, Stores}
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Shifts.CashMovement

  @doc """
  The organization's customers by name. Options: `q:` (part of the name or
  phone), `active_only:` (default false).
  """
  def list_customers(opts \\ []) do
    Customer
    |> search(opts[:q])
    |> then(fn query -> if opts[:active_only], do: where(query, active: true), else: query end)
    |> order_by([c], asc: c.name, asc: c.id)
    |> Repo.all()
  end

  defp search(query, q) when q in [nil, ""], do: query

  defp search(query, q) do
    like = "%" <> String.trim(q) <> "%"
    where(query, [c], like(c.name, ^like) or like(c.phone, ^like))
  end

  @doc "A customer of the current organization; raises `Ecto.NoResultsError` otherwise."
  def get_customer!(id), do: Repo.get!(Customer, id)

  @doc """
  Adds a customer. An admin may set the credit limit; anyone else's customer
  gets none (limit 0), whatever the attrs say.
  """
  def create_customer(%User{} = user, attrs) do
    Repo.put_org_id(user.organization_id)

    %Customer{}
    |> customer_changeset(user, attrs)
    |> Repo.insert()
  end

  @doc "Changes a customer, limit included. Admins only."
  def update_customer(%User{role: "admin"} = user, %Customer{} = customer, attrs) do
    Repo.put_org_id(user.organization_id)

    customer
    |> Customer.admin_changeset(attrs)
    |> Repo.update()
  end

  def update_customer(_user, _customer, _attrs), do: {:error, :unauthorized}

  @doc "Activates or deactivates a customer. Admins only."
  def set_active(%User{role: "admin"} = user, %Customer{} = customer, active?) do
    update_customer(user, customer, %{active: active?})
  end

  def set_active(_user, _customer, _active?), do: {:error, :unauthorized}

  @doc "A changeset for the customer form: with the limit for an admin."
  def change_customer(%User{} = user, %Customer{} = customer, attrs \\ %{}),
    do: customer_changeset(customer, user, attrs)

  defp customer_changeset(customer, %User{role: "admin"}, attrs),
    do: Customer.admin_changeset(customer, attrs)

  defp customer_changeset(customer, _user, attrs), do: Customer.changeset(customer, attrs)

  @doc """
  What a customer owes: the debt of their credit sales still completed
  (total − down payment), less their repayments not cancelled, plus any
  overpayment already handed back. Negative means the customer paid more than
  they owe (after a return or void).
  """
  def balance(%Customer{id: id}), do: balance(id)

  def balance(customer_id) do
    debt =
      Repo.one(
        from s in Sale,
          where:
            s.customer_id == ^customer_id and s.payment_method == "credit" and
              s.status == "completed",
          select: coalesce(sum(s.total - s.amount_paid), 0)
      )

    paid =
      Repo.one(
        from p in Payment,
          where: p.customer_id == ^customer_id and is_nil(p.cancelled_at),
          select: coalesce(sum(p.amount), 0)
      )

    handed_back =
      Repo.one(
        from m in CashMovement,
          where: m.customer_id == ^customer_id and m.category == "customer_refund",
          select: coalesce(sum(m.amount), 0)
      )

    debt |> dec() |> Decimal.sub(dec(paid)) |> Decimal.add(dec(handed_back))
  end

  @doc "How much more the customer may owe: the limit less the balance."
  def available_credit(%Customer{} = customer),
    do: Decimal.sub(customer.credit_limit, balance(customer))

  @doc """
  For a credit sale, inside its transaction: locks the customer (`FOR UPDATE`)
  and checks, against the database rather than any struct a screen holds, that
  they are active and that `debt` keeps them within their limit.

  It must be the transaction's first read. MySQL's REPEATABLE READ answers a
  plain SELECT from a snapshot taken at the first one, so a balance read after
  an earlier plain SELECT could miss a sale another tablet committed while
  this one waited for the lock. The same goes for `receive_payment/3` and
  `refund_overpayment/3`, which lock the customer before the shift.
  """
  def lock_for_credit(customer_id, debt) do
    case Repo.one(from c in Customer, where: c.id == ^customer_id, lock: "FOR UPDATE") do
      nil ->
        {:error, :not_found}

      %Customer{active: false} ->
        {:error, :customer_inactive}

      %Customer{} = customer ->
        if Decimal.gt?(Decimal.add(balance(customer), debt), customer.credit_limit),
          do: {:error, :over_credit_limit},
          else: {:ok, customer}
    end
  end

  @doc "A shift's repayments not cancelled, split into cash (in the drawer) and the rest."
  def payments_totals(shift_id) do
    row =
      Repo.one(
        from p in Payment,
          where: p.shift_id == ^shift_id and is_nil(p.cancelled_at),
          select: %{
            cash:
              coalesce(
                sum(
                  fragment("CASE WHEN ? = 'cash' THEN ? ELSE 0 END", p.payment_method, p.amount)
                ),
                0
              ),
            all: coalesce(sum(p.amount), 0)
          }
      )

    cash = dec(row.cash)
    %{cash: cash, noncash: Decimal.sub(dec(row.all), cash)}
  end

  @doc """
  Receives a repayment (`"amount"`, `"payment_method"`, `"note"`) on the
  user's open shift, in that shift's store. The customer is locked and the
  amount may not exceed what they owe.
  """
  def receive_payment(%User{} = user, customer_id, attrs) do
    Repo.put_org_id(user.organization_id)

    Repo.transaction(fn ->
      with {:ok, customer} <- lock_customer(customer_id),
           {:ok, shift} <- Shifts.lock_current_shift(user) do
        %Payment{
          customer_id: customer.id,
          store_id: shift.store_id,
          shift_id: shift.id,
          user_id: user.id
        }
        |> Payment.changeset(attrs)
        |> within_balance(customer)
        |> Repo.insert()
        |> ok_or_rollback()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp within_balance(%Ecto.Changeset{valid?: true} = changeset, customer) do
    if Decimal.gt?(Ecto.Changeset.get_field(changeset, :amount), balance(customer)),
      do: Repo.rollback(:over_balance),
      else: changeset
  end

  defp within_balance(changeset, _customer), do: changeset

  @doc """
  A repayment received in one of the scope's stores (any store of the
  organization for "all stores"), with its customer, cashier and store.
  """
  def get_payment!(%Zahlungs.Scope{} = scope, id) do
    store_ids =
      case Zahlungs.Scope.store_id(scope) do
        nil -> Stores.store_ids()
        store_id -> [store_id]
      end

    Payment
    |> where([p], p.id == ^id and p.store_id in ^store_ids)
    |> preload([:customer, :user, :store])
    |> Repo.one!()
  end

  @doc """
  Cancels a repayment entered by mistake, with a reason. Admins only, and only
  while the shift that received it is open: a closed shift's figures are final.
  """
  def cancel_payment(%User{role: "admin"} = user, payment_id, reason) do
    Repo.put_org_id(user.organization_id)

    Repo.transaction(fn ->
      with {:ok, id} <- cast_id(payment_id),
           %Payment{} = payment <- lock_payment(id),
           nil <- payment.cancelled_at,
           %{status: "open"} <- Shifts.lock_shift(payment.shift_id) do
        payment
        |> Payment.cancel_changeset(user.id, reason)
        |> Repo.update()
        |> ok_or_rollback()
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(:not_found)
        %NaiveDateTime{} -> Repo.rollback(:already_cancelled)
        _closed_shift -> Repo.rollback(:shift_closed)
      end
    end)
  end

  def cancel_payment(_user, _payment_id, _reason), do: {:error, :unauthorized}

  # Only repayments received in a store of the current organization.
  defp lock_payment(id) do
    Repo.one(
      from p in Payment,
        where: p.id == ^id and p.store_id in ^Stores.store_ids(),
        lock: "FOR UPDATE"
    )
  end

  @doc """
  Hands a customer's overpayment (a negative balance, after a return or void of
  a note they had paid into) back in cash: a `customer_refund` cash-out on the
  admin's open shift. Admins only.
  """
  def refund_overpayment(%User{role: "admin"} = user, customer_id, amount) do
    Repo.put_org_id(user.organization_id)

    Repo.transaction(fn ->
      with {:ok, customer} <- lock_customer(customer_id),
           {:ok, shift} <- Shifts.lock_current_shift(user),
           :ok <- within_overpayment(customer, amount) do
        shift
        |> Shifts.add_cash_movement(%{
          "category" => "customer_refund",
          "amount" => amount,
          "customer_id" => customer.id,
          "note" => "Kelebihan bayar #{customer.name}"
        })
        |> ok_or_rollback()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def refund_overpayment(_user, _customer_id, _amount), do: {:error, :unauthorized}

  defp within_overpayment(customer, amount) do
    overpaid = Decimal.negate(balance(customer))

    case Decimal.parse(String.trim(to_string(amount))) do
      {amount, ""} ->
        if Decimal.gt?(amount, 0) and not Decimal.gt?(amount, overpaid),
          do: :ok,
          else: {:error, :over_overpayment}

      _ ->
        {:error, :over_overpayment}
    end
  end

  defp lock_customer(customer_id) do
    with {:ok, id} <- cast_id(customer_id),
         %Customer{} = customer <-
           Repo.one(from c in Customer, where: c.id == ^id, lock: "FOR UPDATE") do
      {:ok, customer}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  @doc """
  The customer's credit notes still owed, oldest first:
  `[%{sale, remaining, overdue?}]`.
  """
  def open_notes(%Customer{} = customer) do
    customer
    |> ledger()
    |> Enum.filter(&(&1.kind == :sale and &1.status == :open))
    |> Enum.map(&Map.take(&1, [:sale, :remaining, :overdue?]))
  end

  @doc """
  The customer's ledger (kartu piutang), oldest first: credit notes (`:sale`),
  repayments (`:payment`) and overpayments handed back (`:refund`), each with
  the running `balance` after it.

  Repayments settle the oldest notes first. This is worked out here, never
  stored: each note still completed covers a stretch of the cumulative debt,
  and the money received so far (repayments not cancelled, less what was
  handed back) covers those stretches in order. A cancelled repayment
  (`cancelled?: true`) is listed but moves no balance. A note returned or
  voided (`status: :cancelled`) counts until then, and a `:cancel` entry takes
  its debt off at that time, so earlier balances stay as they were shown.
  """
  def ledger(%Customer{id: id}) do
    sales =
      Repo.all(
        from s in Sale,
          where: s.customer_id == ^id and s.payment_method == "credit",
          order_by: [asc: s.inserted_at, asc: s.id],
          preload: [:store, :user]
      )

    payments =
      Repo.all(
        from p in Payment,
          where: p.customer_id == ^id,
          order_by: [asc: p.inserted_at, asc: p.id],
          preload: [:store, :user, :cancelled_by]
      )

    refunds =
      Repo.all(
        from m in CashMovement,
          where: m.customer_id == ^id and m.category == "customer_refund",
          order_by: [asc: m.inserted_at, asc: m.id]
      )

    # Each note still completed covers a stretch of the cumulative debt: (from, to].
    {notes, _} =
      sales
      |> Enum.filter(&(&1.status == "completed"))
      |> Enum.map_reduce(Decimal.new(0), fn sale, from ->
        to = Decimal.add(from, debt(sale))
        {%{sale: sale, from: from, to: to}, to}
      end)

    received =
      Decimal.sub(
        sum(Enum.filter(payments, &is_nil(&1.cancelled_at))),
        sum(refunds)
      )

    events =
      Enum.map(sales, &{&1.inserted_at, 0, &1.id, {:sale, &1}}) ++
        Enum.map(payments, &{&1.inserted_at, 1, &1.id, {:payment, &1}}) ++
        Enum.map(refunds, &{&1.inserted_at, 2, &1.id, {:refund, &1}}) ++
        for(
          %Sale{status: status} = sale when status != "completed" <- sales,
          do:
            {sale.returned_at || sale.voided_at || sale.inserted_at, 3, sale.id, {:cancel, sale}}
        )

    events
    |> Enum.sort_by(fn {at, rank, id, _event} ->
      {NaiveDateTime.to_gregorian_seconds(at), rank, id}
    end)
    |> Enum.map_reduce(%{balance: Decimal.new(0), received: Decimal.new(0)}, fn {_, _, _, event},
                                                                                acc ->
      entry(event, acc, notes, received)
    end)
    |> elem(0)
  end

  defp entry({:sale, %Sale{status: "completed"} = sale}, acc, notes, received) do
    left = notes |> Enum.find(&(&1.sale.id == sale.id)) |> remaining(received)
    balance = Decimal.add(acc.balance, debt(sale))

    {%{
       kind: :sale,
       at: sale.inserted_at,
       amount: debt(sale),
       balance: balance,
       sale: sale,
       remaining: left,
       status: if(Decimal.gt?(left, 0), do: :open, else: :paid),
       overdue?: Decimal.gt?(left, 0) and overdue?(sale)
     }, %{acc | balance: balance}}
  end

  # A note returned or voided later still counted until then: the ledger keeps
  # the balances people saw (and receipts printed), and a :cancel entry takes
  # its debt off when it happened.
  defp entry({:sale, sale}, acc, _notes, _received) do
    balance = Decimal.add(acc.balance, debt(sale))

    {%{
       kind: :sale,
       at: sale.inserted_at,
       amount: debt(sale),
       balance: balance,
       sale: sale,
       remaining: Decimal.new(0),
       status: :cancelled,
       overdue?: false
     }, %{acc | balance: balance}}
  end

  defp entry({:cancel, sale}, acc, _notes, _received) do
    balance = Decimal.sub(acc.balance, debt(sale))

    {%{
       kind: :cancel,
       at: sale.returned_at || sale.voided_at || sale.inserted_at,
       amount: debt(sale),
       balance: balance,
       sale: sale
     }, %{acc | balance: balance}}
  end

  defp entry({:payment, %Payment{cancelled_at: nil} = payment}, acc, notes, _received) do
    received = Decimal.add(acc.received, payment.amount)
    balance = Decimal.sub(acc.balance, payment.amount)

    settles =
      for note <- notes,
          Decimal.gt?(note.to, acc.received) and Decimal.lt?(note.from, received),
          do: %{code: note.sale.code, sale_id: note.sale.id, remaining: remaining(note, received)}

    {%{
       kind: :payment,
       at: payment.inserted_at,
       amount: payment.amount,
       balance: balance,
       payment: payment,
       cancelled?: false,
       settles: settles
     }, %{acc | balance: balance, received: received}}
  end

  defp entry({:payment, payment}, acc, _notes, _received) do
    {%{
       kind: :payment,
       at: payment.inserted_at,
       amount: payment.amount,
       balance: acc.balance,
       payment: payment,
       cancelled?: true,
       settles: []
     }, acc}
  end

  defp entry({:refund, movement}, acc, _notes, _received) do
    balance = Decimal.add(acc.balance, movement.amount)

    {%{
       kind: :refund,
       at: movement.inserted_at,
       amount: movement.amount,
       balance: balance,
       movement: movement
     }, %{acc | balance: balance, received: Decimal.sub(acc.received, movement.amount)}}
  end

  # What is left of a note once `received` (cumulative) has covered the debt
  # before it and as much of its own as it reaches.
  defp remaining(%{from: from, to: to}, received) do
    if Decimal.gt?(to, received),
      do: Decimal.sub(to, Decimal.max(from, received)),
      else: Decimal.new(0)
  end

  defp debt(%Sale{} = sale), do: Decimal.sub(sale.total, sale.amount_paid)

  defp overdue?(%Sale{due_date: nil}), do: false

  defp overdue?(%Sale{due_date: due_date, store: store}),
    do: Date.before?(due_date, LocalTime.today(store))

  defp sum(rows), do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.amount))

  @doc """
  Receivables (laporan piutang): every customer of the organization who owes
  something, most owed first, as `%{customer, balance, oldest_open, overdue,
  last_payment_at}` (`oldest_open` is the oldest note still owed, `overdue`
  what is left of the notes past their due date), and their `total`. Option
  `overdue_only: true` keeps the customers with something overdue.
  """
  def receivables_report(opts \\ []) do
    customers = Repo.all(from c in Customer, order_by: c.name)
    ids = Enum.map(customers, & &1.id)

    debts =
      totals_by_customer(
        from(s in Sale,
          where:
            s.customer_id in ^ids and s.payment_method == "credit" and s.status == "completed",
          group_by: s.customer_id,
          select: {s.customer_id, sum(s.total - s.amount_paid)}
        )
      )

    paid =
      totals_by_customer(
        from(p in Payment,
          where: p.customer_id in ^ids and is_nil(p.cancelled_at),
          group_by: p.customer_id,
          select: {p.customer_id, sum(p.amount)}
        )
      )

    handed_back =
      totals_by_customer(
        from(m in CashMovement,
          where: m.customer_id in ^ids and m.category == "customer_refund",
          group_by: m.customer_id,
          select: {m.customer_id, sum(m.amount)}
        )
      )

    last_payment =
      Map.new(
        Repo.all(
          from p in Payment,
            where: p.customer_id in ^ids and is_nil(p.cancelled_at),
            group_by: p.customer_id,
            select: {p.customer_id, max(p.inserted_at)}
        )
      )

    rows =
      customers
      |> Enum.map(fn c ->
        balance =
          Map.get(debts, c.id, Decimal.new(0))
          |> Decimal.sub(Map.get(paid, c.id, Decimal.new(0)))
          |> Decimal.add(Map.get(handed_back, c.id, Decimal.new(0)))

        {c, balance}
      end)
      |> Enum.filter(fn {_c, balance} -> Decimal.gt?(balance, 0) end)
      |> Enum.map(fn {c, balance} ->
        notes = open_notes(c)

        %{
          customer: c,
          balance: balance,
          oldest_open: notes |> List.first() |> then(&(&1 && &1.sale)),
          overdue: notes |> Enum.filter(& &1.overdue?) |> Enum.map(& &1.remaining) |> add_up(),
          last_payment_at: Map.get(last_payment, c.id)
        }
      end)
      |> Enum.reject(&(opts[:overdue_only] && not Decimal.gt?(&1.overdue, 0)))
      |> Enum.sort_by(& &1.balance, {:desc, Decimal})

    %{rows: rows, total: rows |> Enum.map(& &1.balance) |> add_up()}
  end

  defp totals_by_customer(query) do
    query |> Repo.all() |> Map.new(fn {id, amount} -> {id, dec(amount)} end)
  end

  defp add_up(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  @doc """
  Repayments received (not cancelled) in a range of local dates, in the
  scope's store or, for "all stores", every store of the organization:
  `%{total, by_method: [{method, amount}], by_store: [{store_name, amount}]}`.
  """
  def payments_report(%Zahlungs.Scope{} = scope, %Date{} = from, %Date{} = to) do
    {start, finish} = LocalTime.day_range(from, to, scope.store)

    store_ids =
      case Zahlungs.Scope.store_id(scope) do
        nil -> Stores.store_ids()
        store_id -> [store_id]
      end

    payments =
      from p in Payment,
        where:
          p.store_id in ^store_ids and is_nil(p.cancelled_at) and p.inserted_at >= ^start and
            p.inserted_at <= ^finish

    by_method =
      Repo.all(
        from p in payments,
          group_by: p.payment_method,
          order_by: p.payment_method,
          select: {p.payment_method, sum(p.amount)}
      )
      |> Enum.map(fn {method, amount} -> {method, dec(amount)} end)

    by_store =
      Repo.all(
        from p in payments,
          join: s in assoc(p, :store),
          group_by: [s.id, s.name],
          order_by: s.name,
          select: {s.name, sum(p.amount)}
      )
      |> Enum.map(fn {name, amount} -> {name, dec(amount)} end)

    %{
      total: by_method |> Enum.map(&elem(&1, 1)) |> add_up(),
      by_method: by_method,
      by_store: by_store
    }
  end

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(nil), do: Decimal.new(0)
end
