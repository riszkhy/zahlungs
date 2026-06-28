defmodule Zahlungs.Sales.Sale do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sales" do
    field :code, :string
    field :subtotal, :decimal, default: Decimal.new(0)
    field :discount, :decimal, default: Decimal.new(0)
    field :tax, :decimal, default: Decimal.new(0)
    field :total, :decimal, default: Decimal.new(0)
    field :amount_paid, :decimal, default: Decimal.new(0)
    field :change_due, :decimal, default: Decimal.new(0)
    field :status, :string, default: "completed"

    belongs_to :user, Zahlungs.Accounts.User
    has_many :items, Zahlungs.Sales.SaleItem

    timestamps()
  end

  @doc false
  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [
      :code,
      :user_id,
      :subtotal,
      :discount,
      :tax,
      :total,
      :amount_paid,
      :change_due,
      :status
    ])
    |> validate_required([:subtotal, :total, :amount_paid, :change_due, :status])
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
end
