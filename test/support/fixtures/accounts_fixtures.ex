defmodule Zahlungs.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Zahlungs.Accounts` context.
  """

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  @doc """
  A cashier in the test's default store. Pass `store_id:` for another store, or
  `store_id: nil` for a user without one.
  """
  def user_fixture(attrs \\ %{}) do
    Zahlungs.StoresFixtures.default_org()

    {store_id, attrs} =
      attrs
      |> Map.new()
      |> Map.pop_lazy(:store_id, fn -> Zahlungs.StoresFixtures.default_store().id end)

    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Zahlungs.Accounts.register_user()

    if store_id do
      {:ok, user} = Zahlungs.Accounts.set_user_store(user, store_id)
      user
    else
      user
    end
  end

  @doc "The platform operator: belongs to no organization."
  def superadmin_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Zahlungs.Accounts.create_platform_admin()

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end
end
