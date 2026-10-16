defmodule Zahlungs.Deposits.Account do
  @moduledoc """
  An owner's deposit (balance) at a PPOB provider, e.g. "Pusat" or "Konter
  cabang 2". Each store sells services from one; services take their cost out
  of it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "deposit_accounts" do
    field :name, :string
    field :active, :boolean, default: true

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :active])
    # Spaces only are cast to nil, which validate_required then reports.
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> Zahlungs.Organizations.put_organization()
    |> unsafe_validate_unique(:name, Zahlungs.Repo)
    |> unique_constraint(:name, name: :deposit_accounts_organization_id_name_index)
  end
end
