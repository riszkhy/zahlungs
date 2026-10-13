defmodule Zahlungs.Organizations.Signup do
  @moduledoc """
  The public sign-up form: a business and its owner in one. Not stored itself —
  `Zahlungs.Organizations.register/1` turns it into an organization, a first
  store and the owner's user account.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :business_name, :string
    field :phone, :string
    field :name, :string
    field :email, :string
    field :password, :string, redact: true
  end

  def changeset(signup, attrs) do
    signup
    |> cast(attrs, [:business_name, :phone, :name, :email, :password])
    |> validate_required([:business_name, :name, :email, :password])
    |> validate_length(:business_name, max: 160)
    |> validate_length(:phone, max: 40)
    |> validate_length(:name, max: 160)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 12, max: 72)
  end

  @doc """
  Carries the user changeset's errors (an email already in use, a password the
  account rules refuse) over to the form's changeset, on the same field names.
  """
  def copy_errors(changeset, user_changeset) do
    Enum.reduce(user_changeset.errors, changeset, fn {field, {message, opts}}, acc ->
      if field in [:name, :email, :password],
        do: add_error(acc, field, message, opts),
        else: add_error(acc, :email, "could not create the account")
    end)
    |> Map.put(:action, :insert)
  end
end
