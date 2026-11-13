defmodule ZahlungsWeb.ServiceCorrection do
  @moduledoc """
  The popup where an admin corrects a service's final status
  (`Zahlungs.Services.correct_status/5`), shared by the service history and
  the reconciliation report. The pages hold the state (`correcting`) and handle
  `review_correction`, `cancel_correction` and `confirm_correction`; this module
  draws the popup and words the outcome.
  """
  use Phoenix.Component

  import ZahlungsWeb.CoreComponents, only: [format_price: 1]

  alias Phoenix.LiveView.JS
  alias Zahlungs.{Accounts, Services}
  alias Zahlungs.Services.Transaction
  alias ZahlungsWeb.MdComponents

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
    <MdComponents.md_dialog id="correct-service" show on_cancel={JS.push("cancel_correction")}>
      <:title>{if @to == "failed", do: "Jadikan gagal", else: "Jadikan berhasil"}</:title>

      <dl class="mt-3 space-y-1 text-body-md">
        <div class="flex justify-between gap-4">
          <dt class="text-on-surface-variant">Kode</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.code}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-on-surface-variant">Produk</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.product_name}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-on-surface-variant">Nomor pelanggan</dt>
          <dd class="min-w-0 break-words text-right">{@transaction.customer_ref}</dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt class="text-on-surface-variant">Harga</dt>
          <dd>{format_price(@transaction.price)}</dd>
        </div>
        <div class="flex justify-between gap-4 font-medium">
          <dt class="text-on-surface-variant">Status</dt>
          <dd><.status_badge status={@transaction.status} /> → <.status_badge status={@to} /></dd>
        </div>
      </dl>

      <p class="mt-3 rounded-md3-sm bg-warning-container px-3 py-2 text-body-md text-on-warning-container">
        <%= if @to == "failed" do %>
          Uang {format_price(@transaction.price)} menunggu dikembalikan ke pelanggan oleh kasir.
        <% else %>
          Uang {format_price(@transaction.price)} tidak jadi dikembalikan ke pelanggan; transaksi dihitung berhasil.
        <% end %>
      </p>

      <form id="correct-service-form" phx-submit="confirm_correction" class="mt-4 space-y-3">
        <MdComponents.md_text_field
          :if={@to == "success"}
          name="token_sn"
          value={@token_sn}
          label="SN / token (opsional)"
          maxlength="64"
          autocomplete="off"
        />
        <input :if={@to == "failed"} type="hidden" name="token_sn" value="" />
        <MdComponents.md_text_field
          type="textarea"
          name="reason"
          value={@reason}
          label="Alasan"
          maxlength="200"
          rows="2"
          required
        />
        <p :if={@error} role="alert" class="text-body-sm text-error">{@error}</p>
      </form>

      <:actions>
        <MdComponents.md_button variant="text" type="button" phx-click="cancel_correction">
          Batal
        </MdComponents.md_button>
        <MdComponents.md_button
          variant={if @to == "failed", do: "danger", else: "filled"}
          type="submit"
          form="correct-service-form"
          phx-disable-with="Menyimpan..."
        >
          {if @to == "failed", do: "Jadikan gagal", else: "Jadikan berhasil"}
        </MdComponents.md_button>
      </:actions>
    </MdComponents.md_dialog>
    """
  end

  @doc "A service's status as an MD3 badge, the same on every services page."
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <MdComponents.md_badge tone={status_tone(@status)}>{status_label(@status)}</MdComponents.md_badge>
    """
  end

  defp status_tone("success"), do: "success"
  defp status_tone("failed"), do: "error"
  defp status_tone(_processing), do: "warning"

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
