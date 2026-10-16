defmodule Zahlungs.Deposits do
  @moduledoc """
  Deposit accounts: what an owner holds at a PPOB provider, and which account
  each store sells services from.

  In Fase 0 the cashier tops up in the provider's own app; Zahlungs records
  the top-ups and the services sold, so the admin can compare its estimate of
  the balance with the provider's (see `Zahlungs.Services`).
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Deposits.Account

  ## Accounts

  @doc "The organization's accounts, by name."
  def list_accounts do
    Repo.all(from a in Account, order_by: a.name)
  end

  @doc "The organization's active accounts, by name."
  def list_active_accounts do
    Repo.all(from a in Account, where: a.active == true, order_by: a.name)
  end

  @doc "Active accounts as `{name, id}` pairs, for a select."
  def account_options do
    Enum.map(list_active_accounts(), &{&1.name, &1.id})
  end

  def get_account!(id), do: Repo.get!(Account, id)

  @doc "Whether `id` is an active account of the current organization."
  def active_account?(nil), do: false

  def active_account?(id) do
    Repo.exists?(from a in Account, where: a.id == ^id and a.active == true)
  end

  def create_account(attrs \\ %{}) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.changeset(account, attrs)
  end
end
