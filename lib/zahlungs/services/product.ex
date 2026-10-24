defmodule Zahlungs.Services.Product do
  @moduledoc """
  A PPOB service a store sells: pulsa, paket data and token PLN at a fixed
  value, or a tagihan (PLN, BPJS, PDAM, ...) whose amount the cashier enters.
  Priced as a cost plus a margin in rupiah or percent (see
  `Zahlungs.Services.price_for/2`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(pulsa paket_data token_pln tagihan)
  @margin_types ~w(amount percent)

  schema "service_products" do
    field :name, :string
    field :category, :string
    field :operator, :string
    # The vendor's code for this product (Fase 1, sold through an api account).
    field :provider_code, :string
    # Token PLN: the vendor's code for the owner check; blank is the
    # provider's default (SBI: CPLNPRA).
    field :provider_check_code, :string
    # Token PLN through an api account: check the meter's owner before the
    # sale, or buy it directly like pulsa.
    field :owner_check, :boolean, default: true
    # A bill: ask the cashier how many months the customer pays at once.
    field :ask_months, :boolean, default: false
    # Fixed-value products: what the provider takes. A tagihan: the provider's
    # fee on top of the bill.
    field :cost, :decimal, default: Decimal.new(0)
    field :margin_type, :string, default: "amount"
    field :margin_value, :decimal, default: Decimal.new(0)
    # A tagihan through an api account: what the shop adds per month on top
    # of the provider's total.
    field :api_extra_fee, :decimal, default: Decimal.new(0)
    # What the vendor last said about the product (catalog refresh, or a
    # transaction's actual cost): its price and whether it can be sold.
    field :provider_price, :decimal
    field :provider_status, :string
    field :provider_checked_at, :naive_datetime
    field :active, :boolean, default: true
    field :deleted_at, :naive_datetime

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  def categories, do: @categories
  def margin_types, do: @margin_types

  @doc "What the vendor can say about a product."
  def provider_statuses, do: ~w(normal gangguan kosong tidak_ditemukan)

  @doc "Whether the amount is entered per transaction (a bill) rather than fixed."
  def bill?(%__MODULE__{category: "tagihan"}), do: true
  def bill?(%__MODULE__{}), do: false

  @doc false
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :category,
      :operator,
      :provider_code,
      :provider_check_code,
      :owner_check,
      :ask_months,
      :cost,
      :margin_type,
      :margin_value,
      :api_extra_fee,
      :active
    ])
    |> validate_required([:name, :category, :cost, :margin_type, :margin_value])
    |> validate_length(:name, max: 160)
    |> validate_inclusion(:operator, Zahlungs.Services.Brand.keys())
    |> validate_length(:provider_code, max: 60)
    |> validate_length(:provider_check_code, max: 60)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:margin_type, @margin_types)
    |> validate_number(:margin_value, greater_than_or_equal_to: 0)
    |> validate_number(:api_extra_fee, greater_than_or_equal_to: 0)
    |> validate_cost()
    |> Zahlungs.Organizations.put_organization()
  end

  # A fixed-value product always costs something; a bill's provider fee may be 0.
  # Checked on the field, not the change: a cost of 0 equals the default and
  # is no change at all.
  defp validate_cost(changeset) do
    cost = get_field(changeset, :cost)
    bill? = get_field(changeset, :category) == "tagihan"

    cond do
      is_nil(cost) -> changeset
      Decimal.negative?(cost) -> add_error(changeset, :cost, "tidak boleh negatif")
      not bill? and not Decimal.gt?(cost, 0) -> add_error(changeset, :cost, "harus lebih dari 0")
      true -> changeset
    end
  end
end
