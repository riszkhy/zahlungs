defmodule Zahlungs.Sales.Sale do
  use Ecto.Schema
  import Ecto.Changeset

  @payment_methods ~w(cash qris card transfer)

  schema "sales" do
    field :code, :string
    field :payment_method, :string, default: "cash"
    field :subtotal, :decimal, default: Decimal.new(0)
    field :discount, :decimal, default: Decimal.new(0)
    field :tax, :decimal, default: Decimal.new(0)
    field :total, :decimal, default: Decimal.new(0)
    field :amount_paid, :decimal, default: Decimal.new(0)
    field :change_due, :decimal, default: Decimal.new(0)
    field :status, :string, default: "completed"
    field :returned_at, :naive_datetime
    field :voided_at, :naive_datetime
    field :void_reason, :string
    # Returned or voided after its shift was closed: still counts toward that
    # shift's (already reconciled) figures.
    field :adjusted_after_shift_close, :boolean, default: false

    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :shift, Zahlungs.Shifts.Shift
    # Always the store of the shift the sale was recorded on.
    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :voided_by, Zahlungs.Accounts.User
    has_many :items, Zahlungs.Sales.SaleItem

    timestamps()
  end

  @doc "Returns the list of valid payment methods."
  def payment_methods, do: @payment_methods

  @doc false
  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [
      :code,
      :user_id,
      :shift_id,
      :store_id,
      :subtotal,
      :discount,
      :tax,
      :total,
      :amount_paid,
      :change_due,
      :status,
      :payment_method
    ])
    |> validate_required([
      :store_id,
      :subtotal,
      :total,
      :amount_paid,
      :change_due,
      :status,
      :payment_method
    ])
    |> validate_inclusion(:payment_method, @payment_methods)
    |> validate_number(:discount, greater_than_or_equal_to: 0)
    |> validate_number(:tax, greater_than_or_equal_to: 0)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> unique_constraint(:code)
  end

  @doc "Changeset used only to set the human-readable code after the id is known."
  def code_changeset(sale, code) do
    sale
    |> cast(%{code: code}, [:code])
    |> validate_required([:code])
    |> unique_constraint(:code)
  end

  @doc "Marks a sale as returned/refunded."
  def return_changeset(sale, after_shift_close? \\ false) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    change(sale,
      status: "returned",
      returned_at: now,
      adjusted_after_shift_close: after_shift_close?
    )
  end

  @doc "Returns true if the sale has been returned/refunded."
  def returned?(%__MODULE__{status: "returned"}), do: true
  def returned?(%__MODULE__{}), do: false

  @doc "Marks a sale as voided (koreksi kesalahan input), recording who and why."
  def void_changeset(sale, user_id, reason, after_shift_close? \\ false) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    sale
    |> cast(%{void_reason: reason}, [:void_reason])
    |> validate_required([:void_reason], message: "alasan wajib diisi")
    |> validate_length(:void_reason, max: 255)
    |> put_change(:status, "void")
    |> put_change(:voided_at, now)
    |> put_change(:voided_by_id, user_id)
    |> put_change(:adjusted_after_shift_close, after_shift_close?)
  end

  @doc "Returns true if the sale has been voided."
  def voided?(%__MODULE__{status: "void"}), do: true
  def voided?(%__MODULE__{}), do: false
end
