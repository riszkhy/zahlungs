defmodule ZahlungsWeb.DepositLive.Index do
  @moduledoc """
  Admin page for PPOB deposit accounts: each account with its estimated
  balance; per account, top-ups (from the admin's own drawer or from outside
  it), reconciling against the provider's balance, and the entries.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, Shifts}
  alias Zahlungs.Deposits.Account
  alias ZahlungsWeb.AmountInput

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Deposit")
     |> assign(:has_shift, Shifts.current_shift(socket.assigns.current_user) != nil)
     |> load_rows()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params),
    do: assign(socket, account: nil, account_form: nil, reconcile: nil)

  defp apply_action(socket, :new, _params) do
    assign(socket,
      account: %Account{},
      account_form: to_form(Deposits.change_account(%Account{})),
      reconcile: nil
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    account = Deposits.get_account!(id)

    assign(socket,
      account: account,
      account_form: to_form(Deposits.change_account(account)),
      reconcile: nil
    )
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(account: Deposits.get_account!(id), account_form: nil, reconcile: nil)
    |> load_account()
  end

  @impl true
  def handle_event("save_account", %{"account" => params}, socket) do
    result =
      case socket.assigns.account do
        %Account{id: nil} -> Deposits.create_account(params)
        account -> Deposits.update_account(account, params)
      end

    case result do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Akun deposit #{account.name} disimpan.")
         |> load_rows()
         |> push_patch(to: ~p"/admin/deposits")}

      {:error, changeset} ->
        {:noreply, assign(socket, :account_form, to_form(changeset))}
    end
  end

  def handle_event("topup", %{"topup" => params}, socket) do
    params = Map.update(params, "amount", "", &digits/1)

    case Deposits.record_topup(socket.assigns.current_user, socket.assigns.account, params) do
      {:ok, _entry} ->
        {:noreply,
         socket |> put_flash(:info, "Isi ulang dicatat.") |> load_account() |> load_rows()}

      {:error, :no_open_shift} ->
        {:noreply, put_flash(socket, :error, "Buka shift dulu untuk mengambil dari kas laci.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Periksa jumlah dan sumber isi ulang.")}
    end
  end

  def handle_event("reconcile_preview", %{"actual_balance" => actual}, socket) do
    {:noreply, assign(socket, :reconcile, preview(socket.assigns.balance, digits(actual)))}
  end

  def handle_event("reconcile", %{"actual_balance" => actual} = params, socket) do
    account = socket.assigns.account

    case Deposits.reconcile(socket.assigns.current_user, account, digits(actual), params["note"]) do
      {:ok, :matched} ->
        {:noreply,
         socket |> put_flash(:info, "Cocok, tidak ada selisih.") |> assign(:reconcile, nil)}

      {:ok, entry} ->
        {:noreply,
         socket
         |> put_flash(:info, "Selisih #{format_money(entry.amount)} disimpan sebagai koreksi.")
         |> assign(:reconcile, nil)
         |> load_account()
         |> load_rows()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Isi saldo dari aplikasi penyedia (angka).")}
    end
  end

  defp preview(_balance, ""), do: nil

  defp preview(balance, actual) do
    %{actual: Decimal.new(actual), difference: Decimal.sub(Decimal.new(actual), balance)}
  end

  defp load_rows(socket), do: assign(socket, :rows, Deposits.list_accounts_with_balance())

  defp load_account(socket) do
    account = socket.assigns.account

    assign(socket,
      balance: Deposits.estimated_balance(account),
      entries: Deposits.list_entries(account)
    )
  end

  # Amounts arrive as typed ("250.000", "250.000,00").
  defp digits(value), do: AmountInput.parse(value)

  defp entry_label(%{kind: "topup", source: "drawer"}), do: "Isi ulang (kas laci)"
  defp entry_label(%{kind: "topup"}), do: "Isi ulang (luar laci)"
  defp entry_label(%{kind: "correction"}), do: "Koreksi"

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Deposit
      <:subtitle>Saldo di penyedia PPOB; perkiraan dari isi ulang dikurangi modal layanan</:subtitle>
      <:actions>
        <.link patch={~p"/admin/deposits/new"}><.button>Akun baru</.button></.link>
      </:actions>
    </.header>

    <.table id="deposit-accounts" rows={@rows}>
      <:col :let={row} label="Akun">{row.account.name}</:col>
      <:col :let={row} label="Perkiraan saldo">{format_money(row.balance)}</:col>
      <:col :let={row} label="Status">
        <span class={if row.account.active, do: "text-green-600", else: "text-gray-400"}>
          {if row.account.active, do: "Aktif", else: "Nonaktif"}
        </span>
      </:col>
      <:action :let={row}>
        <.link patch={~p"/admin/deposits/#{row.account}"}>Buka</.link>
      </:action>
      <:action :let={row}>
        <.link patch={~p"/admin/deposits/#{row.account}/edit"}>Ubah</.link>
      </:action>
    </.table>

    <section :if={@live_action == :show} id="deposit-account" class="mt-8 rounded-lg border border-gray-200 p-5">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h3 class="text-lg font-semibold">{@account.name}</h3>
        <p class="text-sm text-gray-600">Perkiraan saldo <strong class="text-gray-900">{format_money(@balance)}</strong></p>
      </div>

      <div class="mt-4 grid gap-6 md:grid-cols-2">
        <form phx-submit="topup" class="space-y-2">
          <h4 class="font-medium">Isi ulang</h4>
          <label class="block text-sm">
            Jumlah
            <input type="text" inputmode="numeric" name="topup[amount]" required class="form-control" autocomplete="off" />
          </label>
          <label class="block text-sm">
            Sumber uang
            <select name="topup[source]" class="form-control">
              <option value="outside">Dari luar laci (transfer dan lainnya)</option>
              <option :if={@has_shift} value="drawer">Kas laci shift saya</option>
            </select>
          </label>
          <label class="block text-sm">
            Catatan (opsional)
            <input type="text" name="topup[note]" maxlength="255" class="form-control" />
          </label>
          <.button>Catat isi ulang</.button>
        </form>

        <form phx-change="reconcile_preview" phx-submit="reconcile" class="space-y-2">
          <h4 class="font-medium">Cocokkan dengan aplikasi penyedia</h4>
          <label class="block text-sm">
            Saldo di aplikasi penyedia
            <input type="text" inputmode="numeric" name="actual_balance" required class="form-control" autocomplete="off" />
          </label>
          <label class="block text-sm">
            Catatan (opsional)
            <input type="text" name="note" maxlength="200" class="form-control" />
          </label>
          <p :if={@reconcile && Decimal.equal?(@reconcile.difference, 0)} class="text-sm text-green-700">
            Cocok dengan perkiraan.
          </p>
          <p :if={@reconcile && not Decimal.equal?(@reconcile.difference, 0)} class="text-sm text-amber-700">
            Selisih {format_money(@reconcile.difference)}. Bila disimpan, perkiraan disamakan dengan saldo aplikasi.
          </p>
          <.button>Simpan pencocokan</.button>
        </form>
      </div>

      <h4 class="mt-6 font-medium">Riwayat</h4>
      <p :if={@entries == []} class="mt-2 text-sm text-gray-500">Belum ada catatan.</p>
      <div :for={entry <- @entries} class="list-card mt-2">
        <span class="min-w-0 flex-1">
          <span class="block font-medium">{entry_label(entry)}</span>
          <span :if={entry.note} class="block text-xs text-gray-500">{entry.note}</span>
          <span class="block text-xs text-gray-400">
            {Calendar.strftime(Zahlungs.LocalTime.to_local(entry.inserted_at, @current_scope.store), "%d %b %Y %H:%M")}
          </span>
        </span>
        <span class="font-semibold">{format_money(entry.amount)}</span>
      </div>
    </section>

    <.modal :if={@account_form} id="deposit-account-modal" show on_cancel={JS.patch(~p"/admin/deposits")}>
      <h3 class="text-lg font-semibold">{if @account.id, do: "Ubah akun deposit", else: "Akun deposit baru"}</h3>
      <.form for={@account_form} id="deposit-account-form" phx-submit="save_account" class="mt-4">
        <.input field={@account_form[:name]} type="text" label="Nama (mis. Pusat, Konter cabang 2)" required />
        <.input field={@account_form[:active]} type="checkbox" label="Aktif" />
        <div class="mt-6"><.button class="w-full">Simpan</.button></div>
      </.form>
    </.modal>
    """
  end
end
