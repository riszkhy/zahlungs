defmodule Zahlungs.Services.Commissions do
  @moduledoc """
  Cashier commission on service transactions (called through
  `Zahlungs.Services`).

  An admin sets a percent of the margin per category (`rates/0`,
  `save_rates/2`). When a cashier records a service, the category's percent
  is copied onto it; anyone else's service gets 0. The amount is never
  stored: it is `floor(max(price − cost, 0) × percent / 100)` for a
  successful service and 0 otherwise, so every path that settles a service
  (the provider's answer, a callback, a review) is right without knowing
  about commission.
  """

  import Ecto.Query, warn: false

  alias Zahlungs.Accounts.User
  alias Zahlungs.{LocalTime, Repo, Scope, Stores}
  alias Zahlungs.Services.{CommissionRate, Transaction}
  alias Zahlungs.Shifts.Shift

  @doc "Every category with its percent (0 where none is set), in display order."
  def rates do
    stored = Map.new(Repo.all(CommissionRate), &{&1.category, &1.percent})

    for {category, label} <- Zahlungs.Services.categories() do
      %{category: category, label: label, percent: Map.get(stored, category, Decimal.new(0))}
    end
  end

  @doc "The percent of one category (0 when none is set)."
  def percent(category) do
    Repo.one(from r in CommissionRate, where: r.category == ^category, select: r.percent) ||
      Decimal.new(0)
  end

  @doc """
  Saves the percents of `values` (category => text; blank is 0), all or none.
  Only an admin may. Returns `{:ok, rates}` or `{:error, %{category => message}}`;
  unknown categories are ignored.
  """
  def save_rates(%User{role: "admin"}, values) when is_map(values) do
    parsed =
      for {category, _label} <- Zahlungs.Services.categories(),
          Map.has_key?(values, category),
          do: {category, parse(values[category])}

    case for({category, {:error, message}} <- parsed, into: %{}, do: {category, message}) do
      errors when errors == %{} ->
        store(for {category, {:ok, value}} <- parsed, do: {category, value})

      errors ->
        {:error, errors}
    end
  end

  def save_rates(%User{}, _values), do: {:error, :unauthorized}

  @doc """
  The percent a service recorded now by `user` carries: the category's for a
  cashier, 0 for anyone else. The role is read from the database, not from
  the struct (a screen may hold one from before a role change).
  """
  def percent_for(%User{id: user_id}, category) do
    case Repo.one(from u in User, where: u.id == ^user_id, select: u.role) do
      "cashier" -> percent(category)
      _other -> Decimal.new(0)
    end
  end

  @doc "A service's commission in whole rupiah: nothing unless it succeeded."
  def commission(%Transaction{status: "success"} = transaction) do
    transaction.price
    |> Decimal.sub(transaction.cost)
    |> Decimal.max(0)
    |> Decimal.mult(transaction.commission_percent)
    |> Decimal.div(100)
    |> Decimal.round(0, :floor)
  end

  def commission(%Transaction{}), do: Decimal.new(0)

  # The same rule as commission/1, in SQL, so a report's total is the sum of
  # its rows (each rounded down on its own).
  defmacrop commission_of(t) do
    quote do
      fragment(
        "FLOOR(GREATEST(? - ?, 0) * ? / 100)",
        unquote(t).price,
        unquote(t).cost,
        unquote(t).commission_percent
      )
    end
  end

  defmacrop margin_of(t) do
    quote do: fragment("GREATEST(? - ?, 0)", unquote(t).price, unquote(t).cost)
  end

  @doc "The commission of a shift's successful services."
  def shift_total(%Shift{id: shift_id}) do
    total(from t in Transaction, where: t.shift_id == ^shift_id)
  end

  @doc "The commission of the successful services of `query` (transactions)."
  def total(query) do
    Repo.one(
      from t in query,
        where: t.status == "success",
        select: coalesce(sum(commission_of(t)), 0)
    )
    |> to_decimal()
  end

  @doc """
  Commission per cashier for a date range (by when the services were
  recorded, in the store's local time), in the scope's store(s). A cashier's
  scope only ever holds their own row.

  Returns `%{rows: [%{user_id, name, count, margin, commission}], count,
  margin, commission}`; rows by name.
  """
  def report(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    rows =
      Repo.all(
        from t in earning(scope, date_from, date_to),
          join: u in User,
          on: u.id == t.user_id,
          group_by: [t.user_id, u.name, u.email],
          order_by: fragment("COALESCE(?, ?)", u.name, u.email),
          select: %{
            user_id: t.user_id,
            name: coalesce(u.name, u.email),
            count: count(t.id),
            margin: sum(margin_of(t)),
            commission: sum(commission_of(t))
          }
      )
      |> Enum.map(&%{&1 | margin: to_decimal(&1.margin), commission: to_decimal(&1.commission)})

    %{
      rows: rows,
      count: rows |> Enum.map(& &1.count) |> Enum.sum(),
      margin: sum_of(rows, :margin),
      commission: sum_of(rows, :commission)
    }
  end

  @doc """
  The services behind one cashier's commission in a date range, newest first.
  In a cashier's scope `user_id` is ignored: it is always their own.
  """
  def details(%Scope{} = scope, user_id, %Date{} = date_from, %Date{} = date_to) do
    user_id = own_id(scope) || user_id

    Repo.all(
      from t in earning(scope, date_from, date_to),
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        select: %{
          id: t.id,
          code: t.code,
          inserted_at: t.inserted_at,
          product_name: t.product_name,
          category: t.category,
          margin: margin_of(t),
          percent: t.commission_percent,
          commission: commission_of(t)
        }
    )
    |> Enum.map(&%{&1 | margin: to_decimal(&1.margin), commission: to_decimal(&1.commission)})
  end

  # Successful services that earned a commission, in the range and the
  # scope's store(s), and only the cashier's own in a cashier's scope.
  defp earning(scope, date_from, date_to) do
    {start, finish} = LocalTime.day_range(date_from, date_to, scope.store)

    query =
      from t in Transaction,
        where:
          t.status == "success" and t.commission_percent > 0 and t.inserted_at >= ^start and
            t.inserted_at <= ^finish

    query = for_store(query, scope)

    case own_id(scope) do
      nil -> query
      user_id -> where(query, [t], t.user_id == ^user_id)
    end
  end

  # Whose commission a scope is limited to: a non-admin's own.
  defp own_id(%Scope{user: %User{role: "admin"}}), do: nil
  defp own_id(%Scope{user: %User{id: id}}), do: id
  defp own_id(%Scope{}), do: nil

  defp for_store(query, scope) do
    case Scope.store_id(scope) do
      nil -> where(query, [t], t.store_id in ^Stores.store_ids())
      store_id -> where(query, [t], t.store_id == ^store_id)
    end
  end

  defp sum_of(rows, key),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, key)))

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp store(values) do
    Repo.transaction(fn ->
      Enum.each(values, fn {category, percent} ->
        %CommissionRate{}
        |> CommissionRate.changeset(%{category: category, percent: percent})
        |> Repo.insert!(on_conflict: {:replace, [:percent, :updated_at]})
      end)

      rates()
    end)
  end

  defp parse(nil), do: {:ok, Decimal.new(0)}

  defp parse(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, Decimal.new(0)}
      trimmed -> trimmed |> Decimal.parse() |> check()
    end
  end

  defp parse(number) when is_number(number), do: number |> to_string() |> parse()

  defp check({%Decimal{} = value, ""}) do
    cond do
      Decimal.lt?(value, 0) or Decimal.gt?(value, 100) ->
        {:error, "harus antara 0 dan 100"}

      not Decimal.equal?(Decimal.round(value, 2), value) ->
        {:error, "paling banyak 2 angka di belakang koma"}

      true ->
        {:ok, value}
    end
  end

  defp check(_not_a_number), do: {:error, "harus berupa angka (pakai titik untuk desimal)"}
end
