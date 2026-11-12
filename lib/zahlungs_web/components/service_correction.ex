defmodule ZahlungsWeb.ServiceCorrection do
  @moduledoc """
  The popup where an admin corrects a service's final status
  (`Zahlungs.Services.correct_status/5`), shared by the service history and
  the reconciliation report. The pages hold the state (`correcting`) and handle
  `review_correction`, `cancel_correction` and `confirm_correction`; this module
  draws the popup and words the outcome.
  """
  use Phoenix.Component

  import ZahlungsWeb.CoreComponents, only: [modal: 1, button: 1, format_price: 1]

  alias Phoenix.LiveView.JS
  alias Zahlungs.{Accounts, Services}
  alias Zahlungs.Services.Transaction

  @messages %{
    in_review: "Transaksi ini sedang ditinjau. Putuskan di halaman akun deposit.",
    refunded: "Uangnya sudah dikembalikan, tidak bisa dijadikan berhasil.",
    same_status: "Status transaksi sudah berubah. Muat ulang.",
    not_final: "Status transaksi sudah berubah. Muat ulang.",
    reason_required: "Alasan wajib diisi (maks. 200 karakter).",
    invalid_token_sn: "SN terlalu panjang (maks. 64 karakter).",
    not_admin: "Hanya admin yang bisa mengoreksi status."
  }

  @doc "Whether `user` gets the Koreksi status button for `transaction`."
  def button?(user, %Transaction{} = transaction),
    do: Accounts.admin?(user) and Services.correctable?(transaction)

  @doc "The status a correction turns `transaction` to."
  def target(%Transaction{status: "success"}), do: "failed"
  def target(%Transaction{}), do: "success"

  @doc "The flash for a correction's outcome: `{:info | :error, text}`."
  def message({:ok, %Transaction{status: "failed"}}),
    do: {:info, "Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir."}

  def message({:ok, %Transaction{}}), do: {:info, "Status dikoreksi menjadi Berhasil."}
  def message({:error, reason}), do: {:error, Map.fetch!(@messages, reason)}

  @doc "Whether the popup stays open on this error, so what was typed isn't lost."
  def keep_open?(reason), do: reason in [:reason_required, :invalid_token_sn]

  attr :transaction, Transaction, required: true
  attr :error, :string, default: nil
  attr :reason, :string, default: ""
  attr :token_sn, :string, default: ""

  @doc """
  The popup. The modal focuses its first field (SN towards success, else the
  reason); Batal sits at the bottom, before the button that names the action.
  """
  def popup(assigns) do
    assigns = assign(assigns, :to, target(assigns.transaction))

    ~H"""
    <.modal id="correct-service" show on_cancel={JS.push("cancel_correction")}>
      <div class="pr-10">
        <h3 class="text-lg font-semibold">
          {if @to == "failed", do: "Jadikan gagal", else: "Jadikan berhasil"}
        </h3>
      </div>

      <dl class="mt-3 space-y-1 text-sm">
        <div class="flex justify-between gap-4">
          <dt class="text-gray-500">Kode</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.code}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-gray-500">Produk</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.product_name}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-gray-500">Nomor pelanggan</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.customer_ref}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-gray-500">Harga</dt>
          <dd>{format_price(@transaction.price)}</dd>
        </div>
        <div class="flex justify-between gap-4 font-medium">
          <dt class="text-gray-500">Status</dt>
          <dd><.status_badge status={@transaction.status} /> → <.status_badge status={@to} /></dd>
        </div>
      </dl>

      <p class="mt-3 rounded bg-amber-50 px-3 py-2 text-sm text-amber-800">
        <%= if @to == "failed" do %>
          Uang {format_price(@transaction.price)} menunggu dikembalikan ke pelanggan oleh kasir.
        <% else %>
          Uang {format_price(@transaction.price)} tidak jadi dikembalikan ke pelanggan; transaksi dihitung berhasil.
        <% end %>
      </p>

      <form phx-submit="confirm_correction" class="mt-4 space-y-3">
        <label :if={@to == "success"} class="block text-sm">
          SN / token (opsional)
          <input type="text" name="token_sn" value={@token_sn} maxlength="64" class="form-control mt-1" autocomplete="off" />
        </label>
        <input :if={@to == "failed"} type="hidden" name="token_sn" value="" />
        <label class="block text-sm">
          Alasan
          <textarea name="reason" maxlength="200" required rows="2" class="form-control mt-1">{@reason}</textarea>
        </label>
        <p :if={@error} role="alert" class="text-sm text-red-600">{@error}</p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="cancel_correction" class="chip">Batal</button>
          <.button :if={@to == "failed"} class="!bg-red-600" phx-disable-with="Menyimpan...">
            Jadikan gagal
          </.button>
          <.button :if={@to == "success"} phx-disable-with="Menyimpan...">Jadikan berhasil</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-block rounded-full px-2 py-0.5 text-xs",
      @status == "success" && "bg-green-100 text-green-700",
      @status == "failed" && "bg-red-100 text-red-700",
      @status == "processing" && "bg-amber-100 text-amber-800"
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
