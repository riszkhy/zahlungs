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
  alias Zahlungs.Customers.Customer
  alias Zahlungs.Repo

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
end
