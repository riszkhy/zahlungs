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
    field :bill_amount, :decimal
    field :inquiry_ref, :string
    field :expires_at, :naive_datetime
    field :used_at, :naive_datetime

    belongs_to :store, Zahlungs.Stores.Store
    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :service_product, Zahlungs.Services.Product
    belongs_to :deposit_account, Zahlungs.Deposits.Account

    timestamps()
  end

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
      customer_name: answer.customer_name |> to_string() |> String.slice(0, 120),
      period: answer.period |> to_string() |> String.slice(0, 60),
      sheets: answer.sheets,
      bill_amount: answer.bill_amount,
      inquiry_ref: answer.inquiry_ref
    })
    |> validate_number(:sheets, greater_than: 0)
    |> validate_number(:bill_amount, greater_than: 0)
  end
end
