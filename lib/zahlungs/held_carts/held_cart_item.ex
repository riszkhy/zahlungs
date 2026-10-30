defmodule Zahlungs.HeldCarts.HeldCartItem do
  @moduledoc """
  A product and its quantity in a held cart, with the product's name for the
  list. The price is not kept: resuming reads it again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "held_cart_items" do
    field :quantity, :integer
    field :name, :string

    belongs_to :held_cart, Zahlungs.HeldCarts.HeldCart
    belongs_to :product, Zahlungs.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:product_id, :quantity, :name])
    |> validate_required([:product_id, :quantity, :name])
    |> validate_number(:quantity, greater_than: 0)
  end
end
