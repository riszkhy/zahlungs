defmodule Zahlungs.Monitoring do
  @moduledoc """
  The platform operator's view of every organization: is it still in use, how
  big is its business, should it be billed, and do its services have a problem.

  This is the one place monitoring reads across organizations, reachable only
  from the `/platform` pages. It writes nothing and calls no provider.
  """

  import Ecto.Query, warn: false

  alias Zahlungs.Accounts.UserLogin
  alias Zahlungs.Deposits.{Account, Entry}
  alias Zahlungs.{LocalTime, Organizations, Repo, Services}
  alias Zahlungs.Organizations.Organization
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Services.Transaction
  alias Zahlungs.Shifts.Shift
  alias Zahlungs.Stores.Store

  @quiet_after 7 * 86_400
  @asleep_after 30 * 86_400
  @due_soon_days 7

  @doc """
  Every organization's state over the last `days` days (`now − days × 24 hours`
  up to `now`), as `%{rows: [row], summary: summary, at: now}`. A fixed number of
  aggregate queries, whatever the number of organizations; an organization
  without data gets zeros. Rows that aren't an aggregate select only the columns
  shown, so a customer's or provider's details are never read.
  """
  def overview(days, now \\ NaiveDateTime.utc_now()) do
    now = NaiveDateTime.truncate(now, :second)
    since = NaiveDateTime.add(now, -days * 86_400)
    today = now |> LocalTime.to_local() |> NaiveDateTime.to_date()

    organizations = Organizations.list_organizations()
    stores = stores_of(Enum.map(organizations, & &1.organization.id))
    store_ids = Enum.map(stores, & &1.id)

    figures = %{
      last_sale: last_at(Sale, store_ids),
      last_service: last_at(Transaction, store_ids),
      sales: sales_totals(store_ids, since, now),
      services: services_totals(store_ids, since, now),
      open_shifts: open_shifts(store_ids),
      store_logins: store_logins(store_ids),
      stuck: count_services(store_ids, stuck(now)),
      refunds_due: count_services(store_ids, refund_due()),
      in_review: count_services(store_ids, in_review())
    }

    store_rows =
      Enum.group_by(stores, & &1.organization_id, &store_row(&1, figures, now))

    organization_ids = Enum.map(organizations, & &1.organization.id)
    logins = organization_logins(organization_ids)
    deposits = deposits_of(organization_ids)

    rows =
      Enum.map(organizations, fn listed ->
        id = listed.organization.id

        organization_row(
          listed,
          Map.get(store_rows, id, []),
          logins[id],
          Map.get(deposits, id, []),
          now,
          today
        )
      end)

    %{rows: rows, summary: %{}, at: now}
  end

  defp organization_row(listed, stores, last_login_at, deposits, now, today) do
    last_transaction_at = stores |> Enum.map(& &1.last_transaction_at) |> latest()
    open_stores = Enum.filter(stores, & &1.active)
    stuck = sum_of(stores, :stuck)
    refunds_due = sum_of(stores, :refunds_due)
    in_review = sum_of(stores, :in_review)
    negative_deposits = Enum.count(deposits, &Decimal.negative?(&1.balance))

    %{
      organization: listed.organization,
      owner_email: listed.owner_email,
      activity: activity(last_transaction_at, now),
      billing: billing(listed.organization, today),
      last_transaction_at: last_transaction_at,
      last_login_at: last_login_at,
      open_shifts: sum_of(stores, :open_shifts),
      quiet_stores: Enum.count(open_stores, &(&1.activity != :active)),
      active_stores: length(open_stores),
      sales_total: total_of(stores, :sales_total),
      sales_count: sum_of(stores, :sales_count),
      services_total: total_of(stores, :services_total),
      services_count: sum_of(stores, :services_count),
      stuck: stuck,
      refunds_due: refunds_due,
      in_review: in_review,
      negative_deposits: negative_deposits,
      problem?: stuck + refunds_due + in_review + negative_deposits > 0,
      stores: stores,
      deposits: deposits
    }
  end

  defp store_row(store, figures, now) do
    last_transaction_at = latest([figures.last_sale[store.id], figures.last_service[store.id]])
    {sales_total, sales_count} = Map.get(figures.sales, store.id, {Decimal.new(0), 0})
    {services_total, services_count} = Map.get(figures.services, store.id, {Decimal.new(0), 0})

    store
    |> Map.delete(:organization_id)
    |> Map.merge(%{
      # A closed store is shown as closed, not as one gone quiet.
      activity: if(store.active, do: activity(last_transaction_at, now)),
      open_shifts: Map.get(figures.open_shifts, store.id, 0),
      last_transaction_at: last_transaction_at,
      last_login_at: figures.store_logins[store.id],
      sales_total: sales_total,
      sales_count: sales_count,
      services_total: services_total,
      services_count: services_count,
      stuck: Map.get(figures.stuck, store.id, 0),
      refunds_due: Map.get(figures.refunds_due, store.id, 0),
      in_review: Map.get(figures.in_review, store.id, 0)
    })
  end

  defp stores_of(organization_ids) do
    Repo.all(
      from(s in Store,
        where: s.organization_id in ^organization_ids,
        order_by: [asc: s.name, asc: s.id],
        select: map(s, [:id, :organization_id, :name, :code, :active, :utc_offset_hours])
      ),
      skip_org_id: true
    )
  end

  # Any status: a sale voided later still shows the store was in use.
  defp last_at(schema, store_ids) do
    Repo.all(
      from r in schema,
        where: r.store_id in ^store_ids,
        group_by: r.store_id,
        select: {r.store_id, max(r.inserted_at)}
    )
    |> Map.new()
  end

  defp sales_totals(store_ids, since, now) do
    Repo.all(
      from s in Sale,
        where:
          s.store_id in ^store_ids and s.status == "completed" and s.inserted_at >= ^since and
            s.inserted_at <= ^now,
        group_by: s.store_id,
        select: {s.store_id, sum(s.total), count(s.id)}
    )
    |> Map.new(fn {store_id, total, count} -> {store_id, {total, count}} end)
  end

  defp services_totals(store_ids, since, now) do
    Repo.all(
      from t in Transaction,
        where:
          t.store_id in ^store_ids and t.status == "success" and t.inserted_at >= ^since and
            t.inserted_at <= ^now,
        group_by: t.store_id,
        select: {t.store_id, sum(t.price), count(t.id)}
    )
    |> Map.new(fn {store_id, total, count} -> {store_id, {total, count}} end)
  end

  defp open_shifts(store_ids) do
    Repo.all(
      from s in Shift,
        where: s.store_id in ^store_ids and s.status == "open",
        group_by: s.store_id,
        select: {s.store_id, count(s.id)}
    )
    |> Map.new()
  end

  defp store_logins(store_ids) do
    Repo.all(
      from(l in UserLogin,
        where: l.store_id in ^store_ids,
        group_by: l.store_id,
        select: {l.store_id, max(l.inserted_at)}
      ),
      skip_org_id: true
    )
    |> Map.new()
  end

  # An admin may log in without a store, so this isn't the stores' latest.
  defp organization_logins(organization_ids) do
    Repo.all(
      from(l in UserLogin,
        where: l.organization_id in ^organization_ids,
        group_by: l.organization_id,
        select: {l.organization_id, max(l.inserted_at)}
      ),
      skip_org_id: true
    )
    |> Map.new()
  end

  defp count_services(store_ids, condition) do
    Repo.all(
      from t in Transaction,
        where: t.store_id in ^store_ids,
        where: ^condition,
        group_by: t.store_id,
        select: {t.store_id, count(t.id)}
    )
    |> Map.new()
  end

  # The same wait as `Services.awaiting_too_long?/2`.
  defp stuck(now) do
    limit = NaiveDateTime.add(now, -Services.settle_by_hand_after())

    dynamic([t], t.channel == "api" and t.status == "processing" and t.inserted_at <= ^limit)
  end

  # The same rule as `Services.list_refunds_due/1`.
  defp refund_due do
    dynamic(
      [t],
      t.channel == "api" and t.status == "failed" and is_nil(t.refunded_at) and
        is_nil(t.review_reason)
    )
  end

  defp in_review, do: dynamic([t], not is_nil(t.review_reason))

  # Active accounts by organization, each with what `Deposits.estimated_balance/1`
  # gives: entries less the cost of the services processing or successful on it.
  defp deposits_of(organization_ids) do
    accounts =
      Repo.all(
        from(a in Account,
          where: a.organization_id in ^organization_ids and a.active,
          order_by: [asc: a.name, asc: a.id],
          select: map(a, [:id, :organization_id, :name])
        ),
        skip_org_id: true
      )

    account_ids = Enum.map(accounts, & &1.id)

    entries =
      Repo.all(
        from(e in Entry,
          where: e.deposit_account_id in ^account_ids,
          group_by: e.deposit_account_id,
          select: {e.deposit_account_id, sum(e.amount)}
        ),
        skip_org_id: true
      )
      |> Map.new()

    used =
      Repo.all(
        from t in Transaction,
          where: t.deposit_account_id in ^account_ids and t.status in ["processing", "success"],
          group_by: t.deposit_account_id,
          select: {t.deposit_account_id, sum(t.cost)}
      )
      |> Map.new()

    Enum.group_by(accounts, & &1.organization_id, fn account ->
      balance =
        entries
        |> Map.get(account.id, Decimal.new(0))
        |> Decimal.sub(Map.get(used, account.id, Decimal.new(0)))

      %{id: account.id, name: account.name, balance: balance}
    end)
  end

  defp latest(times) do
    times |> Enum.reject(&is_nil/1) |> Enum.max(NaiveDateTime, fn -> nil end)
  end

  defp sum_of(rows, field), do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()

  defp total_of(rows, field) do
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, field)))
  end

  @doc """
  How recently an organization or store was used, from its last transaction:
  `:active`, `:quiet`, `:asleep`, or `:never`. Counted in hours, so it doesn't
  depend on a store's time zone; the edge of a band belongs to the more active one.
  """
  def activity(nil, _now), do: :never

  def activity(%NaiveDateTime{} = last_at, %NaiveDateTime{} = now) do
    case NaiveDateTime.diff(now, last_at) do
      waited when waited <= @quiet_after -> :active
      waited when waited <= @asleep_after -> :quiet
      _waited -> :asleep
    end
  end

  @doc """
  Where an active organization stands with its bill: `:unrecorded`, `:overdue`,
  `:due_soon` (today up to a week ahead) or `:ok`; `nil` for any other status.
  """
  def billing(%Organization{status: "active", paid_until: nil}, _today), do: :unrecorded

  def billing(%Organization{status: "active", paid_until: %Date{} = paid_until}, today) do
    cond do
      Date.compare(paid_until, today) == :lt -> :overdue
      Date.compare(paid_until, Date.add(today, @due_soon_days)) != :gt -> :due_soon
      true -> :ok
    end
  end

  def billing(%Organization{}, _today), do: nil
end
