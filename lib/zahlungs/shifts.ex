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
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Shifts.Shift

  @doc "Returns the user's currently open shift, or nil."
  def current_shift(%User{} = user) do
    Repo.one(
      from s in Shift, where: s.user_id == ^user.id and s.status == "open", limit: 1
    )
  end

  @doc """
  Opens a shift for the user with the given opening cash float.
  Returns `{:error, :already_open}` if the user already has an open shift.
  """
  def open_shift(%User{} = user, opening_cash) do
    if current_shift(user) do
      {:error, :already_open}
    else
      %Shift{}
      |> Shift.open_changeset(%{
        user_id: user.id,
        opening_cash: to_decimal(opening_cash),
        opened_at: now(),
        status: "open"
      })
      |> Repo.insert()
    end
  end

  @doc """
  Closes an open shift: computes expected cash and variance vs the counted cash.
  Returns `{:error, :not_open}` if the shift is already closed.
  """
  def close_shift(shift, counted_cash, note \\ nil)

  def close_shift(%Shift{status: "open"} = shift, counted_cash, note) do
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
  end

  def close_shift(%Shift{}, _counted_cash, _note), do: {:error, :not_open}

  @doc """
  Expected cash in the drawer for a shift = opening float + completed **cash**
  sales tagged to the shift. Non-cash sales (QRIS/card/transfer) never enter the
  drawer, so they are excluded. (Returned sales are excluded; cross-shift refunds
  are a future refinement — see docs/CONCEPT-cashier-shift.md.)
  """
  def expected_cash(%Shift{} = shift) do
    cash_total =
      Repo.one(
        from s in Sale,
          where:
            s.shift_id == ^shift.id and s.status == "completed" and
              s.payment_method == "cash",
          select: coalesce(sum(s.total), 0)
      )

    Decimal.add(to_decimal(shift.opening_cash), to_decimal(cash_total))
  end

  @doc """
  Summary for the close/detail screen: opening float, transaction count, cash vs
  non-cash sales totals, and the expected drawer cash (opening + cash sales).
  """
  def shift_summary(%Shift{} = shift) do
    row =
      Repo.one(
        from s in Sale,
          where: s.shift_id == ^shift.id and s.status == "completed",
          select: %{
            transactions: count(s.id),
            sales_total: coalesce(sum(s.total), 0),
            cash_total:
              coalesce(sum(fragment("CASE WHEN ? = 'cash' THEN ? ELSE 0 END", s.payment_method, s.total)), 0)
          }
      )

    sales_total = to_decimal(row.sales_total)
    cash_total = to_decimal(row.cash_total)
    noncash_total = Decimal.sub(sales_total, cash_total)
    opening = to_decimal(shift.opening_cash)

    %{
      opening_cash: opening,
      transactions: row.transactions,
      sales_total: sales_total,
      cash_total: cash_total,
      noncash_total: noncash_total,
      expected_cash: Decimal.add(opening, cash_total)
    }
  end

  @doc """
  Lists shifts (most recent first), preloading the cashier.

  Options: `:limit` (default 50), `:user_id` (restrict to one cashier).
  """
  def list_shifts(opts \\ []) do
    limit = opts[:limit] || 50

    Shift
    |> maybe_filter_user(opts[:user_id])
    |> order_by(desc: :opened_at)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, user_id), do: where(query, [s], s.user_id == ^user_id)

  def get_shift!(id), do: Shift |> Repo.get!(id) |> Repo.preload(:user)

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
