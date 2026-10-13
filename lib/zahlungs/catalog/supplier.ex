defmodule Zahlungs.Catalog.Supplier do
  use Ecto.Schema
  import Ecto.Changeset

  schema "suppliers" do
    field :name, :string
    field :phone, :string
    field :note, :string
    field :deleted_at, :naive_datetime

    has_many :products, Zahlungs.Catalog.Product

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  @doc false
  def changeset(supplier, attrs) do
    supplier
    |> cast(attrs, [:name, :phone, :note])
    |> validate_required([:name])
    |> validate_length(:name, max: 160)
    |> validate_length(:phone, max: 40)
    |> validate_length(:note, max: 255)
    |> Zahlungs.Organizations.put_organization()
  end
end
