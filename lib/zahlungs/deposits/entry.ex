defmodule Zahlungs.Deposits.Entry do
  @moduledoc """
  Money into (or a correction of) a deposit account: a `topup`, paid from the
  drawer or from outside it, or a `correction` with its reason. The account,
  kind and recorder are set by `Zahlungs.Deposits`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(drawer outside)

  schema "deposit_entries" do
    field :kind, :string
    field :amount, :decimal
    field :source, :string
    field :note, :string

    belongs_to :organization, Zahlungs.Organizations.Organization
    belongs_to :deposit_account, Zahlungs.Deposits.Account
    belongs_to :cash_movement, Zahlungs.Shifts.CashMovement
    belongs_to :recorded_by, Zahlungs.Accounts.User

    timestamps()
  end

  @doc "A top-up: a positive amount, from the drawer or from outside it."
  def topup_changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:amount, :source, :note])
    |> validate_required([:amount, :source])
    |> validate_number(:amount, greater_than: 0)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:note, max: 255)
    |> Zahlungs.Organizations.put_organization()
  end

  @doc "A correction: any amount but zero, with the reason."
  def correction_changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:amount, :note])
    |> validate_required([:amount])
    |> validate_required([:note], message: "isi alasan koreksi")
    |> validate_length(:note, max: 255)
    |> validate_change(:amount, fn :amount, amount ->
      if Decimal.equal?(amount, 0), do: [amount: "tidak boleh 0"], else: []
    end)
    |> Zahlungs.Organizations.put_organization()
  end
end
