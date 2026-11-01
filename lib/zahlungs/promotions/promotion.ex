defmodule Zahlungs.Promotions.Promotion do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(percent amount)

  schema "promotions" do
    field :name, :string
    # "percent" (value 0-100) or "amount" (rupiah off each unit).
    field :kind, :string, default: "percent"
    field :value, :decimal
    # Store-local dates, both included.
    field :starts_on, :date
    field :ends_on, :date
    field :all_stores, :boolean, default: true
    field :active, :boolean, default: true

    # What the form edits; saved as targets and stores by Zahlungs.Promotions.
    field :product_ids, {:array, :integer}, virtual: true, default: []
    field :category_ids, {:array, :integer}, virtual: true, default: []
    field :store_ids, {:array, :integer}, virtual: true, default: []

    belongs_to :organization, Zahlungs.Organizations.Organization
    has_many :targets, Zahlungs.Promotions.PromotionTarget
    has_many :stores, Zahlungs.Promotions.PromotionStore

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(promotion, attrs) do
    promotion
    |> cast(attrs, [
      :name,
      :kind,
      :value,
      :starts_on,
      :ends_on,
      :all_stores,
      :active,
      :product_ids,
      :category_ids,
      :store_ids
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind, :value, :starts_on, :ends_on])
    |> validate_length(:name, max: 80)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:value, greater_than: 0)
    |> validate_percent()
    |> validate_dates()
    |> validate_targets()
    |> validate_stores()
    |> Zahlungs.Organizations.put_organization()
  end

  defp validate_percent(changeset) do
    if get_field(changeset, :kind) == "percent",
      do: validate_number(changeset, :value, less_than_or_equal_to: 100),
      else: changeset
  end

  defp validate_dates(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)

    if starts_on && ends_on && Date.before?(ends_on, starts_on),
      do: add_error(changeset, :ends_on, "tidak boleh sebelum tanggal mulai"),
      else: changeset
  end

  defp validate_targets(changeset) do
    if get_field(changeset, :product_ids) == [] and get_field(changeset, :category_ids) == [],
      do: add_error(changeset, :product_ids, "pilih minimal satu produk atau kategori"),
      else: changeset
  end

  defp validate_stores(changeset) do
    if get_field(changeset, :all_stores) == false and get_field(changeset, :store_ids) == [],
      do: add_error(changeset, :store_ids, "pilih minimal satu cabang"),
      else: changeset
  end
end
