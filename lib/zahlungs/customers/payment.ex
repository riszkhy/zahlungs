defmodule Zahlungs.Customers.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  @payment_methods ~w(cash qris card transfer)

  # A repayment of a customer's credit, received on a cashier's open shift.
  # Never deleted: a mistake is cancelled by an admin while that shift is open.
  schema "customer_payments" do
    field :amount, :decimal
    field :payment_method, :string, default: "cash"
    field :note, :string
    field :cancelled_at, :naive_datetime
    field :cancel_reason, :string

    belongs_to :customer, Zahlungs.Customers.Customer
    # The receiving shift and its store, never taken from input.
    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :shift, Zahlungs.Shifts.Shift
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :cancelled_by, Zahlungs.Accounts.User

    timestamps()
  end

  @doc "Returns the list of valid payment methods."
  def payment_methods, do: @payment_methods

  @doc false
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:amount, :payment_method, :note])
    |> validate_required([:amount, :payment_method])
    |> validate_number(:amount, greater_than: 0)
    |> validate_inclusion(:payment_method, @payment_methods)
    |> validate_length(:note, max: 255)
  end

  @doc "Cancels a repayment entered by mistake."
  def cancel_changeset(payment, user_id, reason) do
    payment
    |> cast(%{cancel_reason: reason}, [:cancel_reason])
    |> update_change(:cancel_reason, &String.trim/1)
    |> validate_required([:cancel_reason])
    |> validate_length(:cancel_reason, max: 255)
    |> put_change(:cancelled_by_id, user_id)
    |> put_change(:cancelled_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end
end
