defmodule Zahlungs.Customers.Customer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "customers" do
    field :name, :string
    field :phone, :string
    field :note, :string
    # 0 = may not buy on credit. Only an admin changes it (admin_changeset/2).
    field :credit_limit, :decimal, default: Decimal.new(0)
    # An inactive customer can't buy on credit any more, but can still repay.
    field :active, :boolean, default: true

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  @doc "Name, phone and note: what anyone at the cashier may set."
  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :phone, :note])
    |> validate()
  end

  @doc "Also the credit limit and whether the customer is active: an admin's."
  def admin_changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :phone, :note, :credit_limit, :active])
    |> validate_required([:credit_limit])
    |> validate_number(:credit_limit, greater_than_or_equal_to: 0)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_length(:phone, max: 20)
    |> validate_length(:note, max: 255)
    |> Zahlungs.Organizations.put_organization()
    |> unsafe_validate_unique(:name, Zahlungs.Repo)
    |> unique_constraint(:name, name: :customers_organization_id_name_index)
  end
end
