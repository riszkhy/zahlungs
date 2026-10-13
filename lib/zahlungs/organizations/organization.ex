defmodule Zahlungs.Organizations.Organization do
  @moduledoc """
  An owner's account: the tenant. Its stores, users and catalog all carry its id.

  `status` is `pending` after sign-up, until the platform operator approves
  (`active`) or rejects (`rejected`) it; an active organization can be
  `suspended` and reactivated. Only an active organization's users can log in.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending active suspended rejected)

  schema "organizations" do
    field :name, :string
    field :phone, :string
    field :status, :string, default: "pending"
    field :reviewed_at, :naive_datetime
    field :review_note, :string
    # Billing is manual: what the operator agreed with the owner.
    field :paid_until, :date
    field :billing_note, :string

    belongs_to :reviewed_by, Zahlungs.Accounts.User

    timestamps()
  end

  def statuses, do: @statuses

  @doc "Changeset for the business details given at sign-up."
  def registration_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :phone])
    |> validate_required([:name])
    |> validate_length(:name, max: 160)
    |> validate_length(:phone, max: 40)
  end

  @doc "Changeset for a status change made by the platform operator."
  def review_changeset(organization, status, reviewer_id, note) do
    organization
    |> cast(%{review_note: note}, [:review_note])
    |> validate_length(:review_note, max: 255)
    |> put_change(:status, status)
    |> validate_inclusion(:status, @statuses)
    |> put_change(:reviewed_by_id, reviewer_id)
    |> put_change(:reviewed_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end

  @doc "Changeset for the manual billing record."
  def billing_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:paid_until, :billing_note])
    |> validate_length(:billing_note, max: 255)
  end
end
