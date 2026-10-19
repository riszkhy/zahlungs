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

  alias Zahlungs.Accounts.User
  alias Zahlungs.Deposits.{Account, Credentials, Entry}
  alias Zahlungs.Services.Provider
  alias Zahlungs.Shifts

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

  @doc "The account if it is active (and of the current organization), else nil."
  def get_active_account(nil), do: nil

  def get_active_account(id) do
    Repo.one(from a in Account, where: a.id == ^id and a.active == true)
  end

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

  ## Provider (api mode)

  @doc "Whether Zahlungs talks to the provider for this account (Fase 1)."
  def api?(%Account{mode: mode}), do: mode == "api"

  @doc "Whether credentials are stored (they are never shown back)."
  def credentials_saved?(%Account{credentials: credentials}), do: credentials != nil

  @doc """
  The adapter and the decrypted credentials of an api account:
  `{:ok, adapter, credentials}`; `:manual` for a manual account; and
  `{:error, :credentials}` when stored credentials can't be read (e.g. the
  secret key changed).
  """
  def provider(%Account{mode: "api", provider: key, credentials: encrypted}) do
    with {:ok, adapter} <- Provider.adapter(key),
         {:ok, credentials} <- Credentials.decrypt(encrypted) do
      {:ok, adapter, credentials}
    else
      _ -> {:error, :credentials}
    end
  end

  def provider(%Account{}), do: :manual

  @doc "The account a provider's callback is for, by its token, in any organization."
  def get_account_by_callback_token(token) when is_binary(token) do
    Repo.one(from(a in Account, where: a.callback_token == ^token), skip_org_id: true)
  end

  def get_account_by_callback_token(_token), do: nil

  @doc "Asks the provider whether it can be reached with these credentials."
  def ping(%Account{} = account) do
    case provider(account) do
      {:ok, adapter, credentials} -> adapter.ping(credentials)
      :manual -> {:error, "Akun ini mode manual."}
      {:error, :credentials} -> {:error, "Kredensial tidak bisa dibaca. Isi ulang kredensialnya."}
    end
  end

  @doc "The balance the provider holds for this account, where the adapter can tell."
  def provider_balance(%Account{} = account) do
    with {:ok, adapter, credentials} <- provider(account),
         {:module, _} <- Code.ensure_loaded(adapter),
         true <- function_exported?(adapter, :balance, 1) do
      adapter.balance(credentials)
    else
      _ -> {:error, :unsupported}
    end
  end

  ## Entries

  @doc """
  Records a top-up (`attrs`: `"amount"`, `"source"` — `"drawer"` or
  `"outside"` — and an optional `"note"`).

  From the drawer, the same money is booked as a `deposit_topup` cash-out on the
  admin's open shift, in one transaction; without an open shift that is
  `{:error, :no_open_shift}`.
  """
  def record_topup(%User{} = admin, %Account{} = account, attrs) do
    changeset = Entry.topup_changeset(new_entry(admin, account, "topup"), attrs)

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      Ecto.Changeset.get_field(changeset, :source) == "drawer" ->
        topup_from_drawer(admin, account, changeset)

      true ->
        Repo.insert(changeset)
    end
  end

  # The cash-out and the entry stand or fall together.
  defp topup_from_drawer(admin, account, changeset) do
    Repo.transaction(fn ->
      case insert_drawer_topup(admin, account, changeset) do
        {:ok, entry} -> entry
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Inside topup_from_drawer/3's transaction: the shift stays locked until it ends.
  defp insert_drawer_topup(admin, account, changeset) do
    with {:ok, shift} <- Shifts.lock_current_shift(admin),
         {:ok, movement} <-
           Shifts.add_cash_movement(shift, %{
             category: "deposit_topup",
             amount: Ecto.Changeset.get_field(changeset, :amount),
             note: "Isi deposit: #{account.name}"
           }) do
      changeset
      |> Ecto.Changeset.put_change(:cash_movement_id, movement.id)
      |> Repo.insert()
    end
  end

  @doc "Records a correction (`attrs`: `\"amount\"`, not 0, and `\"note\"`, the reason)."
  def record_correction(%User{} = admin, %Account{} = account, attrs) do
    admin
    |> new_entry(account, "correction")
    |> Entry.correction_changeset(attrs)
    |> Repo.insert()
  end

  defp new_entry(admin, account, kind) do
    %Entry{
      kind: kind,
      deposit_account_id: account.id,
      organization_id: account.organization_id,
      recorded_by_id: admin.id
    }
  end

  @doc "The account's entries, newest first."
  def list_entries(%Account{id: account_id}) do
    Repo.all(
      from e in Entry,
        where: e.deposit_account_id == ^account_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  ## Balance

  @doc """
  What the account should hold: top-ups and corrections, less the cost of the
  services processing or successful on it.
  """
  def estimated_balance(%Account{id: account_id} = account) do
    entries =
      Repo.one(
        from e in Entry,
          where: e.deposit_account_id == ^account_id,
          select: coalesce(sum(e.amount), 0)
      )

    entries |> to_decimal() |> Decimal.sub(Zahlungs.Services.deposit_used(account))
  end

  @doc "The organization's accounts, each with `balance`: its estimated balance."
  def list_accounts_with_balance do
    Enum.map(list_accounts(), &%{account: &1, balance: estimated_balance(&1)})
  end

  @doc """
  Compares the balance the provider's app shows with the estimate. Equal:
  `{:ok, :matched}`. Otherwise the difference is recorded as a correction (its
  note says so, plus the admin's `note`), after which the estimate equals the
  provider's balance and the next reconciliation shows only what changed since.
  """
  def reconcile(%User{} = admin, %Account{} = account, actual_balance, note \\ nil) do
    with {:ok, actual} <- actual_balance(actual_balance) do
      difference = Decimal.sub(actual, estimated_balance(account))

      if Decimal.equal?(difference, 0) do
        {:ok, :matched}
      else
        record_correction(admin, account, %{
          "amount" => difference,
          "note" => reconcile_note(actual, note)
        })
      end
    end
  end

  defp actual_balance(value) do
    {%{}, %{actual_balance: :decimal}}
    |> Ecto.Changeset.cast(%{actual_balance: value}, [:actual_balance])
    |> Ecto.Changeset.validate_required([:actual_balance])
    |> Ecto.Changeset.validate_number(:actual_balance, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, %{actual_balance: actual}} -> {:ok, actual}
      error -> error
    end
  end

  defp reconcile_note(actual, note) do
    base = "Pencocokan: saldo aplikasi #{rupiah(actual)}"

    case note && String.trim(note) do
      value when value in [nil, ""] -> base
      value -> "#{base} — #{value}"
    end
  end

  # "Rp 430.000": whole rupiah, dots between thousands.
  defp rupiah(amount) do
    digits = amount |> Decimal.round(0) |> Decimal.abs() |> Decimal.to_string(:normal)

    grouped =
      digits |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1.") |> String.reverse()

    if Decimal.negative?(amount), do: "-Rp #{grouped}", else: "Rp #{grouped}"
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
end
