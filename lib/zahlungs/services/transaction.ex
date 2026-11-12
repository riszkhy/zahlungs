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
  import Ecto.Query, only: [dynamic: 2]

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
    # Fase 1: the account's mode when recorded, and what the provider says.
    field :channel, :string, default: "manual"
    field :ref_id, :string
    field :provider_ref, :string
    field :provider_message, :string
    field :sent_at, :naive_datetime
    field :last_checked_at, :naive_datetime
    field :sheets, :integer, default: 1
    field :customer_name, :string
    field :period, :string
    field :failed_after_shift_close, :boolean, default: false
    field :refunded_at, :naive_datetime
    # Copies of what was sent and answered: the vendor's code, the cost as
    # quoted when recorded (`cost` becomes the vendor's actual charge), the last
    # raw answer, and the tariff/power from a token PLN check.
    field :provider_code, :string
    field :quoted_cost, :decimal
    field :provider_payload, :string
    field :customer_details, :string
    # A paid bill's reference at its biller, and the meter's reading (PLN).
    field :bill_reference, :string
    field :meter_reading, :string
    # An answer that contradicts the final status, for an admin to decide.
    field :review_reason, :string
    field :reviewed_at, :naive_datetime
    # An admin's last correction of a final status (`Services.correct_status/5`).
    field :corrected_at, :naive_datetime
    field :correction_reason, :string
    # The cashier commission of the category when recorded, a percent or an
    # amount (the other is 0; both 0 when not recorded by a cashier). Never cast;
    # see `Zahlungs.Services.Commissions`.
    field :commission_percent, :decimal, default: Decimal.new(0)
    field :commission_amount, :decimal, default: Decimal.new(0)

    belongs_to :service_inquiry, Zahlungs.Services.Inquiry
    belongs_to :refunded_by, Zahlungs.Accounts.User
    belongs_to :reviewed_by, Zahlungs.Accounts.User
    belongs_to :corrected_by, Zahlungs.Accounts.User

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
  Whether a failed service's money is still waiting to go back to the
  customer (and so still in its drawer): an api failure until a cashier
  confirms the refund, and a manual one only when an admin's correction failed
  it. A manual service marked failed was handed back on the spot.
  """
  def awaiting_refund?(%__MODULE__{status: "failed", refunded_at: nil} = transaction),
    do: transaction.channel == "api" or not is_nil(transaction.corrected_at)

  def awaiting_refund?(%__MODULE__{}), do: false

  @doc "`awaiting_refund?/1` as a query condition on the first binding."
  def awaiting_refund do
    dynamic(
      [t],
      t.status == "failed" and is_nil(t.refunded_at) and
        (t.channel == "api" or not is_nil(t.corrected_at))
    )
  end

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
    |> unique_constraint(:ref_id)
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
