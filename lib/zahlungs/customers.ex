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
  alias Zahlungs.Repo
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

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(nil), do: Decimal.new(0)
end
