defmodule Zahlungs.Services.Inquiry do
  @moduledoc """
  A PLN bill as the provider described it (Fase 1): customer, period, sheets
  and amount. Valid for 15 minutes and used once, by `Zahlungs.Services.record/3`
  — so what the customer pays comes from here, never from the browser.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "service_inquiries" do
    field :customer_ref, :string
    field :customer_name, :string
    field :period, :string
    field :sheets, :integer, default: 1
    # How many months the customer asked to pay (a bill whose provider offers a choice).
    field :months, :integer
    field :bill_amount, :decimal
    field :inquiry_ref, :string
    # The ref Zahlungs sent (a bill is paid with the same one), what the
    # provider adds and its total, and the tariff/power it described.
    field :ref_id, :string
    field :provider_admin, :decimal
    field :provider_total, :decimal
    field :details, :string
    # "bill" (tagihan PLN) or "customer" (the owner of a token PLN meter).
    field :kind, :string, default: "bill"
    field :expires_at, :naive_datetime
    field :used_at, :naive_datetime

    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :service_product, Zahlungs.Services.Product
    belongs_to :deposit_account, Zahlungs.Deposits.Account

    timestamps()
  end

  def kinds, do: ~w(bill customer)

  @doc "The customer number, cleaned and checked like a transaction's."
  def number_changeset(%__MODULE__{} = inquiry, attrs) do
    inquiry
    |> cast(attrs, [:customer_ref])
    |> update_change(:customer_ref, &String.replace(&1, ~r/[\s\-\.\+]/, ""))
    |> validate_required([:customer_ref], message: "isi ID pelanggan")
    |> validate_format(:customer_ref, ~r/^\d{6,20}$/, message: "harus 6–20 angka")
  end

  @doc false
  def answer_changeset(changeset, answer) do
    changeset
    |> change(%{
      customer_name: clip(answer.customer_name, 120),
      period: clip(answer.period, 60),
      # A provider that doesn't say how many months the bill covers: the months asked.
      sheets: Map.get(answer, :sheets) || get_field(changeset, :months) || 1,
      bill_amount: answer.bill_amount,
      provider_admin: Map.get(answer, :provider_admin),
      provider_total: Map.get(answer, :provider_total) || answer.bill_amount,
      details: answer |> Map.get(:details) |> clip(120),
      inquiry_ref: answer.inquiry_ref
    })
    |> validate_number(:sheets, greater_than: 0)
    |> validate_bill()
  end

  # A bill needs an amount; a token PLN owner check has none.
  defp validate_bill(changeset) do
    if get_field(changeset, :kind) == "customer",
      do: changeset,
      else: validate_number(changeset, :bill_amount, greater_than: 0)
  end

  defp clip(nil, _max), do: nil
  defp clip(value, max), do: value |> to_string() |> String.trim() |> String.slice(0, max)
end
