defmodule Zahlungs.Deposits.Account do
  @moduledoc """
  An owner's deposit (balance) at a PPOB provider, e.g. "Pusat" or "Konter
  cabang 2". Each store sells services from one; services take their cost out
  of it.

  `mode` is `manual` (Fase 0: the cashier works in the provider's own app) or
  `api` (Zahlungs talks to the provider through the `provider` adapter, with
  the encrypted `credentials`; the provider calls back on `callback_token`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Zahlungs.Deposits.Credentials
  alias Zahlungs.Services.Provider

  @modes ~w(manual api)

  schema "deposit_accounts" do
    field :name, :string
    field :active, :boolean, default: true
    field :mode, :string, default: "manual"
    field :provider, :string
    field :credentials, :binary, redact: true
    field :callback_token, :string, redact: true

    belongs_to :organization, Zahlungs.Organizations.Organization

    timestamps()
  end

  def modes, do: @modes

  @doc """
  `attrs` may carry `"credentials"`: a map of the provider's credential fields.
  Blank values keep what is stored, so the form can leave them empty.
  """
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :active, :mode, :provider])
    # Spaces only are cast to nil, which validate_required then reports.
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name, :mode])
    |> validate_length(:name, max: 80)
    |> validate_inclusion(:mode, @modes)
    |> put_credentials(attrs["credentials"] || attrs[:credentials])
    |> validate_api()
    |> Zahlungs.Organizations.put_organization()
    |> unsafe_validate_unique(:name, Zahlungs.Repo)
    |> unique_constraint(:name, name: :deposit_accounts_organization_id_name_index)
    |> unique_constraint(:callback_token)
  end

  # Merges the non-blank values into what is stored, encrypted again.
  defp put_credentials(changeset, entered) when is_map(entered) do
    stored = stored_credentials(changeset)

    filled =
      for {key, value} <- entered,
          is_binary(value),
          String.trim(value) != "",
          into: %{},
          do: {to_string(key), value}

    merged = Map.merge(stored, filled)

    if merged == stored,
      do: changeset,
      else: put_change(changeset, :credentials, Credentials.encrypt(merged))
  end

  defp put_credentials(changeset, _entered), do: changeset

  defp stored_credentials(changeset) do
    case Credentials.decrypt(get_field(changeset, :credentials)) do
      {:ok, credentials} -> credentials
      :error -> %{}
    end
  end

  # An api account needs a provider Zahlungs knows, every credential that
  # provider asks for, and a callback token (made once).
  defp validate_api(changeset) do
    if get_field(changeset, :mode) == "api" do
      case Provider.adapter(get_field(changeset, :provider)) do
        {:ok, adapter} ->
          changeset |> require_credentials(adapter) |> put_callback_token()

        :error ->
          add_error(changeset, :provider, "pilih penyedia")
      end
    else
      changeset
    end
  end

  defp require_credentials(changeset, adapter) do
    stored = stored_credentials(changeset)
    missing = for {key, _label} <- adapter.credential_fields(), blank?(stored[key]), do: key

    if missing == [],
      do: changeset,
      else: add_error(changeset, :credentials, "lengkapi kredensial penyedia")
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp put_callback_token(changeset) do
    if get_field(changeset, :callback_token),
      do: changeset,
      else:
        put_change(
          changeset,
          :callback_token,
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )
  end
end
