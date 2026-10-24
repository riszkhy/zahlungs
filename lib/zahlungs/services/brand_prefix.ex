defmodule Zahlungs.Services.BrandPrefix do
  @moduledoc """
  One mobile number prefix (first four digits) and the brand it names. Kept by
  the platform operator for every organization, so it has no
  `organization_id`. Written only by `Zahlungs.Services.save_brand_prefixes/1`.
  """
  use Ecto.Schema

  schema "brand_prefixes" do
    field :brand, :string
    field :prefix, :string

    timestamps()
  end
end
