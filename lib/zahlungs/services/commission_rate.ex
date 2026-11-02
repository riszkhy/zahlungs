defmodule Zahlungs.Services.CommissionRate do
  @moduledoc """
  The cashier commission of one service category in an organization: a
  percent of each successful service's margin, or a rupiah amount per service
  (`kind`; the other value stays 0). A category without a row is 0%.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Zahlungs.Services.Product

  schema "service_commission_rates" do
    field :category, :string
    field :kind, :string, default: "percent"
    field :percent, :decimal, default: Decimal.new(0)
    field :amount, :decimal, default: Decimal.new(0)

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  def changeset(rate, attrs) do
    rate
    |> cast(attrs, [:category, :kind, :percent, :amount])
    |> validate_required([:category, :kind, :percent, :amount])
    |> validate_inclusion(:category, Product.categories())
    |> validate_inclusion(:kind, ~w(percent amount))
    |> validate_number(:percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:amount, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000_000)
    |> Zahlungs.Organizations.put_organization()
    |> unique_constraint(:category,
      name: :service_commission_rates_organization_id_category_index
    )
  end
end
