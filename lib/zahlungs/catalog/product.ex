defmodule Zahlungs.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :sku, :string
    field :name, :string
    field :description, :string
    field :image_url, :string
    field :price, :decimal, default: Decimal.new(0)
    field :stock, :integer, default: 0
    field :active, :boolean, default: true

    belongs_to :category, Zahlungs.Catalog.Category

    timestamps()
  end

  @doc false
  def changeset(product, attrs) do
    product
    |> cast(attrs, [:sku, :name, :description, :image_url, :price, :stock, :active, :category_id])
    |> validate_required([:sku, :name, :price, :stock])
    |> validate_length(:sku, max: 80)
    |> validate_length(:name, max: 160)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:stock, greater_than_or_equal_to: 0)
    |> unsafe_validate_unique(:sku, Zahlungs.Repo)
    |> unique_constraint(:sku)
    |> assoc_constraint(:category)
  end
end
