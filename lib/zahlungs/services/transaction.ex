defmodule Zahlungs.Services.Transaction do
  @moduledoc """
  One PPOB service sold. Recorded when the cashier takes the money
  (`processing`), then marked `success` (with the token or serial number) or
  `failed` (the money goes back to the customer). Both results are final.

  Everything the money depends on — store, shift, deposit account, price,
  cost — is set by `Zahlungs.Services`, never cast from a form.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(processing success failed)

  schema "service_transactions" do
    field :code, :string
    field :category, :string
    field :product_name, :string
    field :customer_ref, :string
    field :bill_amount, :decimal
    field :price, :decimal
    field :cost, :decimal
    field :payment_method, :string, default: "cash"
    field :amount_paid, :decimal
    field :change_due, :decimal, default: Decimal.new(0)
    field :status, :string, default: "processing"
    field :token_sn, :string
    field :failure_reason, :string
    field :resolved_at, :naive_datetime

    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :shift, Zahlungs.Shifts.Shift
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :service_product, Zahlungs.Services.Product
    belongs_to :deposit_account, Zahlungs.Deposits.Account
    belongs_to :resolved_by, Zahlungs.Accounts.User

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Only the customer's number (phone, meter or customer ID) and the payment
  method are taken from the form. Spaces, dashes, dots and a leading `+` are
  dropped from the number, and what is left must be 6 to 20 digits.
  """
  def record_changeset(%__MODULE__{} = transaction, attrs) do
    transaction
    |> cast(attrs, [:customer_ref, :payment_method])
    |> update_change(:customer_ref, &String.replace(&1, ~r/[\s\-\.\+]/, ""))
    |> validate_required([:customer_ref], message: "isi nomor tujuan")
    |> validate_format(:customer_ref, ~r/^\d{6,20}$/, message: "harus 6–20 angka")
    |> validate_inclusion(:payment_method, Zahlungs.Sales.Sale.payment_methods())
    |> unique_constraint(:code, name: :service_transactions_store_id_code_index)
  end

  @doc """
  The result: `success` with an optional token or serial number, or `failed`
  with the reason. `resolved_by_id` and `resolved_at` are set by the context.
  """
  def resolve_changeset(%__MODULE__{} = transaction, attrs) do
    transaction
    |> cast(attrs, [:status, :token_sn, :failure_reason])
    |> update_change(:token_sn, &String.trim/1)
    |> validate_inclusion(:status, ~w(success failed))
    |> validate_length(:token_sn, max: 64)
    |> validate_length(:failure_reason, max: 255)
    |> require_reason_when_failed()
  end

  defp require_reason_when_failed(changeset) do
    if get_field(changeset, :status) == "failed",
      do: validate_required(changeset, [:failure_reason], message: "isi alasan gagal"),
      else: changeset
  end
end
