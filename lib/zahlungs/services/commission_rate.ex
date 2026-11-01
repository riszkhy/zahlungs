defmodule Zahlungs.Services.CommissionRate do
  @moduledoc """
  The cashier commission of one service category in an organization: a
  percent of each successful service's margin. A category without a row is 0%.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Zahlungs.Services.Product

  schema "service_commission_rates" do
    field :category, :string
    field :percent, :decimal, default: Decimal.new(0)

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  def changeset(rate, attrs) do
    rate
    |> cast(attrs, [:category, :percent])
    |> validate_required([:category, :percent])
    |> validate_inclusion(:category, Product.categories())
    |> validate_number(:percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> Zahlungs.Organizations.put_organization()
    |> unique_constraint(:category,
      name: :service_commission_rates_organization_id_category_index
    )
  end
end
