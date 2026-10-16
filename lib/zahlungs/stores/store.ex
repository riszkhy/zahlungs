defmodule Zahlungs.Stores.Store do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stores" do
    field :name, :string
    # Short code, unique per store; prefixes invoice numbers.
    field :code, :string
    field :address, :string
    field :phone, :string
    # The store's time zone as a fixed UTC offset (7 = WIB, 8 = WITA, 9 = WIT).
    field :utc_offset_hours, :integer, default: 7
    # Optional; lets the login log show how far from the store a login was made.
    field :latitude, :float
    field :longitude, :float
    field :active, :boolean, default: true

    belongs_to :organization, Zahlungs.Organizations.Organization
    # The deposit account the store sells PPOB services from (see Zahlungs.Deposits).
    belongs_to :deposit_account, Zahlungs.Deposits.Account

    timestamps()
  end

  @doc false
  def changeset(store, attrs) do
    store
    |> cast(attrs, [
      :name,
      :code,
      :address,
      :phone,
      :utc_offset_hours,
      :latitude,
      :longitude,
      :active,
      :deposit_account_id
    ])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:name, :code, :utc_offset_hours])
    |> validate_length(:name, max: 160)
    |> validate_format(:code, ~r/^[A-Z0-9]{2,8}$/, message: "2–8 huruf/angka, tanpa spasi")
    |> validate_number(:utc_offset_hours,
      greater_than_or_equal_to: -12,
      less_than_or_equal_to: 14
    )
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_coordinates_together()
    |> validate_change(:deposit_account_id, &active_deposit_account/2)
    # Checked here too, so a form can say "taken" before anything is saved; the
    # constraint below still guards against two saves racing each other.
    |> Zahlungs.Organizations.put_organization()
    |> unsafe_validate_unique(:code, Zahlungs.Repo)
    |> unique_constraint(:code, name: :stores_organization_id_code_index)
  end

  # An inactive account, or one of another organization (invisible to the
  # Repo guard), can't be the one a store sells from.
  defp active_deposit_account(field, id) do
    if Zahlungs.Deposits.active_account?(id), do: [], else: [{field, "akun deposit tidak aktif"}]
  end

  # A latitude without a longitude (or the reverse) is not a location.
  defp validate_coordinates_together(changeset) do
    case {get_field(changeset, :latitude), get_field(changeset, :longitude)} do
      {nil, lng} when not is_nil(lng) -> add_error(changeset, :latitude, "isi juga latitude")
      {lat, nil} when not is_nil(lat) -> add_error(changeset, :longitude, "isi juga longitude")
      _ -> changeset
    end
  end
end
