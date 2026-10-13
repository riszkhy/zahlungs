defmodule Zahlungs.Shifts.Shift do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cashier_shifts" do
    field :status, :string, default: "open"
    field :opening_cash, :decimal, default: Decimal.new(0)
    field :expected_cash, :decimal
    field :counted_cash, :decimal
    field :variance, :decimal
    field :opened_at, :naive_datetime
    field :closed_at, :naive_datetime
    field :note, :string

    belongs_to :user, Zahlungs.Accounts.User
    # The store whose cash drawer this shift is.
    belongs_to :store, Zahlungs.Stores.Store
    has_many :sales, Zahlungs.Sales.Sale
    has_many :cash_movements, Zahlungs.Shifts.CashMovement

    timestamps()
  end

  @doc "Changeset for opening a shift (starting cash float)."
  def open_changeset(shift, attrs) do
    shift
    |> cast(attrs, [:user_id, :store_id, :opening_cash, :opened_at, :status])
    |> validate_required([:user_id, :store_id, :opening_cash, :opened_at, :status])
    |> validate_number(:opening_cash, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for closing a shift (counted cash + reconciliation)."
  def close_changeset(shift, attrs) do
    shift
    |> cast(attrs, [:status, :closed_at, :expected_cash, :counted_cash, :variance, :note])
    |> validate_required([:status, :closed_at, :expected_cash, :counted_cash, :variance])
    |> validate_number(:counted_cash, greater_than_or_equal_to: 0)
  end

  @doc "Returns true if the shift is currently open."
  def open?(%__MODULE__{status: "open"}), do: true
  def open?(%__MODULE__{}), do: false
end
