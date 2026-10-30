defmodule Zahlungs.HeldCarts.HeldCart do
  @moduledoc """
  A cart put aside (Tunda) in a store, to be resumed by any cashier of that
  store. Its store comes from the cashier's open shift, never from input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "held_carts" do
    field :note, :string
    field :discount, :decimal, default: Decimal.new(0)
    field :tax, :decimal, default: Decimal.new(0)

    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :shift, Zahlungs.Shifts.Shift
    has_many :items, Zahlungs.HeldCarts.HeldCartItem

    timestamps()
  end

  @doc false
  def changeset(held_cart, attrs) do
    held_cart
    |> cast(attrs, [:note, :discount, :tax])
    |> blank_to_zero(:discount)
    |> blank_to_zero(:tax)
    |> validate_length(:note, max: 60)
    |> validate_number(:discount, greater_than_or_equal_to: 0)
    |> validate_number(:tax, greater_than_or_equal_to: 0)
  end

  # An amount left empty on the screen is none.
  defp blank_to_zero(changeset, field) do
    if get_field(changeset, field),
      do: changeset,
      else: put_change(changeset, field, Decimal.new(0))
  end
end
