defmodule Zahlungs.ServicesFixtures do
  @moduledoc """
  Test helpers for PPOB services: deposit accounts, service products and
  service transactions.
  """

  alias Zahlungs.{Deposits, Stores}

  @doc "A deposit account in the current organization (active unless told otherwise)."
  def deposit_account_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()

    {:ok, account} =
      attrs
      |> Enum.into(%{name: "Deposit #{System.unique_integer([:positive])}"})
      |> Deposits.create_account()

    account
  end

  @doc "A service product: pulsa, cost 10.150, margin Rp 1.850 (price 12.000) unless told otherwise."
  def service_product_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()

    {:ok, product} =
      attrs
      |> Enum.into(%{
        name: "Pulsa #{System.unique_integer([:positive])}",
        category: "pulsa",
        cost: "10150",
        margin_type: "amount",
        margin_value: "1850"
      })
      |> Zahlungs.Services.create_product()

    product
  end

  @doc "Makes `account` the one `store` sells services from."
  def assign_account(store, account) do
    {:ok, store} = Stores.update_store(store, %{deposit_account_id: account.id})
    store
  end
end
