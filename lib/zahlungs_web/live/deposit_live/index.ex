defmodule ZahlungsWeb.DepositLive.Index do
  @moduledoc """
  Admin page for PPOB deposit accounts: each account with its estimated
  balance; per account, top-ups (from the admin's own drawer or from outside
  it), reconciling against the provider's balance, and the entries.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, Services, Shifts}
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
  def handle_event("validate_account", %{"account" => params}, socket) do
    changeset =
      socket.assigns.account |> Deposits.change_account(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :account_form, to_form(changeset))}
  end

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

  # An answer that contradicted a final status: the admin decides.
  def handle_event("resolve_review", %{"transaction_id" => id, "decision" => decision}, socket)
      when decision in ["refund", "keep", "success"] do
    transaction = Services.get_account_transaction!(socket.assigns.account, id)
    decision = String.to_existing_atom(decision)

    case Services.resolve_review(transaction, socket.assigns.current_user, decision) do
      {:ok, reviewed} ->
        {:noreply,
         socket |> put_flash(:info, review_message(decision, reviewed)) |> load_account()}

      {:error, :not_in_review} ->
        {:noreply, socket |> put_flash(:error, "Transaksi ini sudah ditinjau.") |> load_account()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Hanya admin yang bisa meninjau.")}
    end
  end

  def handle_event("test_connection", _params, socket) do
    case Deposits.ping(socket.assigns.account) do
      :ok -> {:noreply, put_flash(socket, :info, "Koneksi ke penyedia berhasil.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Koneksi gagal: #{reason}")}
    end
  end

  # The provider's balance goes into the reconciling form, to check and save.
  def handle_event("fetch_balance", _params, socket) do
    case Deposits.provider_balance(socket.assigns.account) do
      {:ok, actual} ->
        {:noreply, assign(socket, :reconcile, preview(socket.assigns.balance, actual))}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Saldo tidak bisa diambil dari penyedia. Isi dari aplikasinya."
         )}
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
      entries: Deposits.list_entries(account),
      in_review: Services.list_in_review(account)
    )
  end

  defp callback_url(account) do
    if Deposits.callback_by_ref?(account),
      do: url(~p"/api/ppob/callback"),
      else: url(~p"/api/ppob/callback/#{account.callback_token}")
  end

  # Amounts arrive as typed ("250.000", "250.000,00").
  defp digits(value), do: AmountInput.parse(value)

  defp entry_label(%{kind: "topup", source: "drawer"}), do: "Isi ulang (kas laci)"
  defp entry_label(%{kind: "topup"}), do: "Isi ulang (luar laci)"
  defp entry_label(%{kind: "correction"}), do: "Koreksi"

  defp review_message(:refund, _transaction),
    do: "Transaksi dibatalkan dan masuk Perlu dikembalikan."

  defp review_message(:keep, %{status: "success"}), do: "Transaksi tetap berhasil."
  defp review_message(:keep, _failed), do: "Transaksi tetap gagal."
  defp review_message(:success, _transaction), do: "Transaksi dijadikan berhasil."

  defp form_field(form, field), do: Ecto.Changeset.get_field(form.source, field)

  defp mode_options,
    do: [
      {"Manual (diproses di aplikasi penyedia)", "manual"},
      {"API (Zahlungs mengirim ke penyedia)", "api"}
    ]

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

      <div :if={Deposits.api?(@account)} class="mt-3 flex flex-wrap gap-2">
        <button type="button" phx-click="test_connection" phx-disable-with="Menghubungi..." class="chip">
          Tes koneksi
        </button>
        <button type="button" phx-click="fetch_balance" phx-disable-with="Mengambil..." class="chip">
          Ambil saldo dari penyedia
        </button>
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
            <input
              type="text"
              inputmode="numeric"
              name="actual_balance"
              value={@reconcile && Decimal.to_string(@reconcile.actual, :normal)}
              required
              class="form-control"
              autocomplete="off"
            />
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

      <div :if={@in_review != []} id="in-review" class="mt-6 rounded-lg border border-amber-200 bg-amber-50 p-4">
        <h4 class="font-medium text-amber-900">Perlu ditinjau ({length(@in_review)})</h4>
        <p class="mt-1 text-xs text-amber-800">
          Jawaban penyedia bertentangan dengan status transaksi. Periksa ke pelanggan dan aplikasi penyedia, lalu putuskan.
        </p>
        <div :for={tx <- @in_review} id={"review-#{tx.id}"} class="mt-3 text-sm">
          <p>
            <span class="font-medium">{tx.product_name}</span>
            · {tx.customer_ref} · {format_money(tx.price)} · {tx.code}
          </p>
          <p class="text-xs text-amber-900">{tx.review_reason}</p>
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              :if={tx.status == "success"}
              type="button"
              phx-click={JS.push("resolve_review", value: %{transaction_id: tx.id, decision: "refund"})}
              data-confirm="Batalkan transaksi ini? Uangnya masuk Perlu dikembalikan untuk diserahkan ke pelanggan."
              class="chip !border-red-300 !text-red-700"
            >
              Batalkan dan kembalikan uang
            </button>
            <button
              :if={tx.status == "failed" && is_nil(tx.refunded_at)}
              type="button"
              phx-click={JS.push("resolve_review", value: %{transaction_id: tx.id, decision: "success"})}
              data-confirm="Jadikan berhasil? Uangnya tidak dikembalikan ke pelanggan."
              class="chip !border-green-300 !text-green-700"
            >
              Jadikan berhasil
            </button>
            <button
              type="button"
              phx-click={JS.push("resolve_review", value: %{transaction_id: tx.id, decision: "keep"})}
              class="chip"
            >
              {if tx.status == "success", do: "Tetap berhasil", else: "Tetap gagal"}
            </button>
          </div>
        </div>
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
      <.form for={@account_form} id="deposit-account-form" phx-change="validate_account" phx-submit="save_account" class="mt-4">
        <.input field={@account_form[:name]} type="text" label="Nama (mis. Pusat, Konter cabang 2)" required />
        <.input field={@account_form[:mode]} type="select" label="Cara memproses layanan" options={mode_options()} />

        <div :if={form_field(@account_form, :mode) == "api"}>
          <.input
            field={@account_form[:provider]}
            type="select"
            label="Penyedia"
            prompt="Pilih penyedia"
            options={Zahlungs.Services.Provider.options()}
          />

          <%!-- Credentials are write-only: the inputs start empty, and a blank one keeps what is stored. --%>
          <label :for={{key, label} <- Deposits.credential_fields(form_field(@account_form, :provider))} class="mt-2 block text-sm">
            {label}
            <span :if={Deposits.credentials_saved?(@account)} class="text-xs text-gray-500">
              (tersimpan, kosongkan bila tidak diganti)
            </span>
            <input type="password" name={"account[credentials][#{key}]"} value="" autocomplete="new-password" class="form-control" />
          </label>

          <p :if={@account.callback_token} class="mt-3 text-sm">
            URL callback untuk penyedia:
            <code class="block break-all rounded bg-gray-50 p-2 text-xs">{callback_url(@account)}</code>
          </p>
        </div>

        <.input field={@account_form[:active]} type="checkbox" label="Aktif" />
        <div class="mt-6"><.button class="w-full">Simpan</.button></div>
      </.form>
    </.modal>
    """
  end
end
