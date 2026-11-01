defmodule Zahlungs.PromotionsFixtures do
  @moduledoc """
  Test helpers for promotions. A promotion runs from yesterday to tomorrow in
  the default store's local date, on a fresh product, unless told otherwise.
  """

  alias Zahlungs.Accounts.User
  alias Zahlungs.{LocalTime, Promotions}
  alias Zahlungs.StoresFixtures

  @doc "An admin of the current organization, as a bare struct (no login needed)."
  def promo_admin do
    %User{role: "admin", organization_id: StoresFixtures.default_org().id}
  end

  def promotion_fixture(attrs \\ %{}) do
    today = LocalTime.today(StoresFixtures.default_store())

    attrs =
      Enum.into(attrs, %{
        name: "Promo #{System.unique_integer([:positive])}",
        kind: "percent",
        value: "10",
        starts_on: Date.add(today, -1),
        ends_on: Date.add(today, 1)
      })

    attrs =
      if Map.has_key?(attrs, :product_ids) or Map.has_key?(attrs, :category_ids),
        do: attrs,
        else: Map.put(attrs, :product_ids, [Zahlungs.CatalogFixtures.product_fixture().id])

    {:ok, promotion} = Promotions.create_promotion(promo_admin(), attrs)
    promotion
  end
end
