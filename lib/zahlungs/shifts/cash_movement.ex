defmodule Zahlungs.Shifts.CashMovement do
  use Ecto.Schema
  import Ecto.Changeset

  # Category => drawer direction. The direction is always derived from the
  # category (never trusted from user input) so it stays consistent.
  @categories %{
    "cash_in" => "in",
    "cash_drop" => "out",
    "expense" => "out",
    "consignment_payment" => "out",
    # Cash handed back for a sale from an already-closed shift; recorded by
    # Zahlungs.Sales.return_sale/2, not entered by hand.
    "refund" => "out"
  }

  schema "cash_movements" do
    field :direction, :string
    field :category, :string
    field :amount, :decimal
    field :note, :string

    belongs_to :shift, Zahlungs.Shifts.Shift
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :supplier, Zahlungs.Catalog.Supplier

    timestamps()
  end

  @doc "List of valid categories."
  def categories, do: Map.keys(@categories)

  @doc "The drawer direction (\"in\"/\"out\") for a category, or nil if unknown."
  def direction_for(category), do: Map.get(@categories, category)

  @doc false
  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:shift_id, :user_id, :supplier_id, :category, :amount, :note])
    |> validate_required([:shift_id, :category, :amount])
    |> validate_inclusion(:category, categories())
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:note, max: 255)
    |> put_direction()
    |> validate_consignment_supplier()
    |> assoc_constraint(:shift)
    |> assoc_constraint(:supplier)
  end

  defp put_direction(changeset) do
    case get_field(changeset, :category) do
      nil -> changeset
      category -> put_change(changeset, :direction, direction_for(category))
    end
  end

  # A consignment payment must name the supplier being paid.
  defp validate_consignment_supplier(changeset) do
    if get_field(changeset, :category) == "consignment_payment" do
      validate_required(changeset, [:supplier_id],
        message: "wajib diisi untuk pembayaran konsinyasi"
      )
    else
      changeset
    end
  end
end
