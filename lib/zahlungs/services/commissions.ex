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
  alias Zahlungs.Repo
  alias Zahlungs.Services.{CommissionRate, Transaction}

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
