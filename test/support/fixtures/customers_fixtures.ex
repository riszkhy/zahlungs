defmodule Zahlungs.CustomersFixtures do
  @moduledoc """
  Test helpers for customers who buy on credit.
  """

  alias Zahlungs.Customers.Customer
  alias Zahlungs.Repo

  @doc "A customer of the current organization, with a credit limit of 1.000.000 unless told otherwise."
  def customer_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()

    attrs =
      Enum.into(attrs, %{
        name: "Pelanggan #{System.unique_integer([:positive])}",
        credit_limit: "1000000"
      })

    %Customer{}
    |> Customer.admin_changeset(attrs)
    |> Repo.insert!()
  end
end
