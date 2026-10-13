defmodule Zahlungs.Catalog.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :deleted_at, :naive_datetime

    has_many :products, Zahlungs.Catalog.Product

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 160)
    |> Zahlungs.Organizations.put_organization()
    |> unsafe_validate_unique(:name, Zahlungs.Repo)
    |> unique_constraint(:name, name: :categories_organization_id_name_index)
  end
end
