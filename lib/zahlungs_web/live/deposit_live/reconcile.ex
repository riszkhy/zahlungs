defmodule ZahlungsWeb.DepositLive.Reconcile do
  @moduledoc """
  Reconciling one deposit account's api services with SBI's transaction
  history for one day (`Services.reconcile/3`), admin only. SBI is asked only
  when the admin presses Cocokkan, never on opening the page. A row's button
  asks SBI about that service again (`Services.recheck_row/2`, which never
  sends a payment) and updates that row only. An admin may also correct a
  row's service by hand (`ZahlungsWeb.ServiceCorrection`), without asking SBI.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, LocalTime, Services}
  alias Zahlungs.Services.Reconciliation
  alias ZahlungsWeb.ServiceCorrection

  # Each kind as the admin sees it, most dangerous first: the order of the
  # chips and the rows. `button` is the row's main button (asks SBI again);
  # a conflict's main button is Koreksi status instead (see `row_card/1`).
  @kinds_ui [
    conflict: %{
      label: "Bertentangan",
      tone: :red,
      hint:
        "Zahlungs dan SBI sama-sama final tapi berbeda. Samakan dengan SBI; cek status dulu bila ragu.",
      button: nil
    },
    theirs_only: %{
      label: "Hanya di SBI",
      tone: :red,
      hint: "SBI memotong saldo, tapi transaksinya tidak ada di akun ini. Tanyakan ke SBI.",
      button: nil
    },
    follow: %{
      label: "Belum final di Zahlungs",
      tone: :amber,
      hint: "SBI sudah final, Zahlungs masih Diproses.",
      button: "Ikuti SBI"
    },
    ours_only: %{
      label: "Hanya di Zahlungs",
      tone: :amber,
      hint: "Terkirim, tapi tidak ada di riwayat SBI.",
      button: "Cek status"
    },
    pending_there: %{
      label: "Belum final di SBI",
      tone: :amber,
      hint: "SBI belum memberi status akhir.",
      button: "Cek status"
    },
    cost_diff: %{
      label: "Selisih modal",
      tone: :amber,
      hint: "Status sama, modal Zahlungs beda dengan potongan SBI.",
      button: nil
    },
    matched: %{label: "Cocok", tone: :green, hint: nil, button: nil}
  ]

  @kind_order @kinds_ui |> Keyword.keys() |> Enum.with_index() |> Map.new()

  @errors %{
    unsupported: "Rekonsiliasi hanya untuk akun api SBI.",
    unavailable: "Riwayat SBI belum bisa diambil, coba lagi.",
    credentials: "Kredensial penyedia tidak bisa dibaca. Isi ulang di halaman akun deposit.",
    future_date: "Tanggal tidak valid atau belum terjadi.",
    not_admin: "Hanya admin yang bisa mencocokkan."
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Rekonsiliasi")
     |> assign(:account, Deposits.get_account!(id))
     |> assign(:date, Date.to_iso8601(Date.add(LocalTime.today(), -1)))
     |> assign(:max_date, Date.to_iso8601(LocalTime.today()))
     |> assign(rows: nil, summary: nil, error: nil, show_matched: false)
     |> close_correction()}
  end

  @impl true
  def handle_event("reconcile", %{"date" => text}, socket) do
    admin = socket.assigns.current_user
    socket = assign(socket, date: text, rows: nil, summary: nil, error: nil, show_matched: false)

    result =
      case Date.from_iso8601(to_string(text)) do
        {:ok, date} -> Services.reconcile(admin, socket.assigns.account, date)
        _ -> {:error, :future_date}
      end

    case result do
      {:ok, %{rows: rows, summary: summary}} ->
        {:noreply, assign(socket, rows: rows, summary: summary)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, Map.fetch!(@errors, reason))}
    end
  end

  def handle_event("toggle_matched", _params, socket),
    do: {:noreply, update(socket, :show_matched, &(not &1))}

  def handle_event("review_correction", %{"index" => index}, socket) do
    with rows when is_list(rows) <- socket.assigns.rows,
         {:ok, i} <- parse_index(index, length(rows)),
         %{ours: %{} = transaction} <- Enum.at(rows, i),
         true <- ServiceCorrection.button?(socket.assigns.current_user, transaction) do
      {:noreply,
       socket |> close_correction() |> assign(:correcting, %{index: i, transaction: transaction})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_correction", _params, socket),
    do: {:noreply, close_correction(socket)}

  # Only while the popup is open: a second click on the way does nothing.
  def handle_event("confirm_correction", _params, %{assigns: %{correcting: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_correction", params, socket) do
    %{index: i, transaction: transaction} = socket.assigns.correcting
    reason = params["reason"] || ""
    token_sn = params["token_sn"] || ""

    result =
      Services.correct_status(
        socket.assigns.current_user,
        transaction,
        ServiceCorrection.target(transaction),
        reason,
        token_sn: token_sn
      )

    {kind, text} = ServiceCorrection.message(result)

    case result do
      {:ok, corrected} ->
        rows = socket.assigns.rows

        rows =
          List.replace_at(rows, i, Reconciliation.classify(corrected, Enum.at(rows, i).theirs))

        {:noreply,
         socket
         |> close_correction()
         |> assign(rows: rows, summary: Services.reconciliation_summary(rows))
         |> put_flash(kind, text)}

      {:error, error} ->
        if ServiceCorrection.keep_open?(error) do
          {:noreply,
           assign(socket,
             correction_error: text,
             correction_reason: reason,
             correction_token_sn: token_sn
           )}
        else
          {:noreply, socket |> close_correction() |> put_flash(kind, text)}
        end
    end
  end

  def handle_event("recheck", %{"index" => index}, socket) do
    with rows when is_list(rows) <- socket.assigns.rows,
         {:ok, i} <- parse_index(index, length(rows)),
         %{ours: %{}} = row <- Enum.at(rows, i) do
      case Services.recheck_row(socket.assigns.current_user, row) do
        {:ok, row} ->
          rows = List.replace_at(rows, i, row)

          {:noreply,
           socket
           |> assign(rows: rows, summary: Services.reconciliation_summary(rows))
           |> put_flash(:info, recheck_message(row))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Baris ini tidak bisa diperiksa ulang.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp close_correction(socket),
    do:
      assign(socket,
        correcting: nil,
        correction_error: nil,
        correction_reason: "",
        correction_token_sn: ""
      )

  defp parse_index(index, count) when is_integer(index) and index >= 0 and index < count,
    do: {:ok, index}

  defp parse_index(index, count) when is_binary(index) do
    case Integer.parse(index) do
      {i, ""} -> parse_index(i, count)
      _ -> :error
    end
  end

  defp parse_index(_index, _count), do: :error

  defp recheck_message(%{kind: :matched}), do: "Sudah cocok dengan SBI."

  defp recheck_message(%{in_review?: true}),
    do: "Masuk Peninjauan. Putuskan di halaman akun deposit."

  defp recheck_message(_row), do: "SBI belum menjawab, coba lagi."

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        indexed: indexed(assigns.rows),
        kinds_ui: @kinds_ui
      )

    ~H"""
    <.header>
      Rekonsiliasi
      <:subtitle>{@account.name} · cocokkan layanan dengan riwayat SBI satu hari.</:subtitle>
      <:actions>
        <.link navigate={~p"/admin/deposits/#{@account}"} class="chip">Kembali</.link>
      </:actions>
    </.header>

    <form phx-submit="reconcile" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="block text-sm">
        Tanggal
        <input type="date" name="date" value={@date} max={@max_date} required class="form-control" />
      </label>
      <.button phx-disable-with="Mencocokkan...">Cocokkan</.button>
    </form>

    <p :if={@error} class="mt-4 text-sm text-red-600">{@error}</p>

    <section :if={@rows} class="mt-6 space-y-4">
      <div class="flex flex-wrap gap-2 text-sm">
        <span
          :for={{kind, ui} <- @kinds_ui}
          class={[
            "rounded-full border px-3 py-1",
            tone_classes(ui.tone),
            @summary.counts[kind] == 0 && "opacity-50"
          ]}
        >
          {ui.label} <strong>{@summary.counts[kind]}</strong>
        </span>
      </div>
      <dl class="flex flex-wrap gap-x-6 gap-y-1 text-sm">
        <div><dt class="inline text-gray-600">Selisih modal</dt> <dd class="inline font-medium">{format_price(@summary.cost_difference)}</dd></div>
        <div><dt class="inline text-gray-600">Potongan tanpa transaksi Zahlungs</dt> <dd class="inline font-medium">{format_price(@summary.theirs_only_total)}</dd></div>
      </dl>

      <p :if={@rows == []} class="text-sm text-gray-600">Tidak ada transaksi pada tanggal ini.</p>

      <ul class="space-y-3">
        <.row_card :for={{row, index} <- @indexed} :if={row.kind != :matched} row={row} index={index} user={@current_user} />
      </ul>

      <div :if={@summary.counts.matched > 0}>
        <button type="button" phx-click="toggle_matched" class="chip">
          {if @show_matched,
            do: "Sembunyikan yang cocok",
            else: "Lihat yang cocok (#{@summary.counts.matched})"}
        </button>
        <ul :if={@show_matched} class="mt-3 space-y-3">
          <.row_card :for={{row, index} <- @indexed} :if={row.kind == :matched} row={row} index={index} user={@current_user} />
        </ul>
      </div>
    </section>

    <ServiceCorrection.popup
      :if={@correcting}
      transaction={@correcting.transaction}
      error={@correction_error}
      reason={@correction_reason}
      token_sn={@correction_token_sn}
    />
    """
  end

  attr :row, :map, required: true
  attr :index, :integer, required: true
  attr :user, :map, required: true

  defp row_card(assigns) do
    row = assigns.row
    ui = Keyword.fetch!(@kinds_ui, row.kind)
    actionable? = row.ours != nil and not row.in_review?
    correct? = row.ours != nil and ServiceCorrection.button?(assigns.user, row.ours)

    assigns =
      assign(assigns,
        ui: ui,
        conflict?: row.kind == :conflict,
        recheck: if(actionable?, do: ui.button),
        correct?: correct?,
        check_sbi?: actionable? and row.kind == :conflict,
        differs?: not same_status?(row.ours, row.theirs),
        cost_note: cost_note(row)
      )

    ~H"""
    <li
      id={"reconcile-row-#{@index}"}
      class={["rounded-lg border border-l-4 border-gray-200 p-4", edge_class(@ui.tone)]}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class={["rounded border px-2 py-0.5 text-xs font-medium", tone_classes(@ui.tone)]}>
            {@ui.label}
          </span>
          <span :if={@row.in_review?} class="rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">Sedang ditinjau</span>
        </div>
        <span class="text-sm text-gray-500">{time(@row)}</span>
      </div>
      <p class="mt-2 min-w-0 break-words font-medium">{(@row.ours && @row.ours.code) || @row.ref || "Tanpa ref"}</p>
      <p :if={@row.ours && @row.ref} class="min-w-0 break-words text-xs text-gray-500">{@row.ref}</p>
      <p class="min-w-0 break-words text-sm text-gray-600">{product(@row)} · {customer(@row)}</p>
      <p :if={@ui.hint} class="mt-1 text-sm">{@ui.hint}</p>
      <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <div class="min-w-0"><dt class="text-gray-500">Di Zahlungs</dt><dd class={@differs? && "font-semibold text-red-700"}>{ours_status(@row.ours)}</dd></div>
        <div class="min-w-0"><dt class="text-gray-500">Di SBI</dt><dd class={@differs? && "font-semibold text-red-700"}>{theirs_status(@row.theirs)}</dd></div>
        <div class="min-w-0"><dt class="text-gray-500">Modal</dt><dd>{money(@row.ours && @row.ours.cost)}</dd></div>
        <div class="min-w-0">
          <dt class="text-gray-500">Potongan SBI</dt>
          <dd>{money(@row.theirs && @row.theirs.cost)}</dd>
          <dd :if={@cost_note} class="text-xs text-red-700">{@cost_note}</dd>
        </div>
      </dl>
      <div :if={@recheck || @correct? || @check_sbi?} class="mt-3 flex flex-wrap gap-2">
        <%= if @conflict? do %>
          <.button :if={@correct?} type="button" phx-click="review_correction" phx-value-index={@index}>
            Koreksi status
          </.button>
          <button :if={@check_sbi?} type="button" phx-click="recheck" phx-value-index={@index} phx-disable-with="Menanyakan SBI..." class="chip">
            Cek status SBI
          </button>
        <% else %>
          <.button :if={@recheck} type="button" phx-click="recheck" phx-value-index={@index} phx-disable-with="Menanyakan SBI...">
            {@recheck}
          </.button>
          <button :if={@correct?} type="button" phx-click="review_correction" phx-value-index={@index} class="chip">
            Koreksi status
          </button>
        <% end %>
      </div>
    </li>
    """
  end

  # The rows with their index in `@rows` (what the buttons send), most
  # dangerous kind first; within a kind, the order `Services.reconcile` gave.
  defp indexed(nil), do: []

  defp indexed(rows),
    do: rows |> Enum.with_index() |> Enum.sort_by(fn {row, i} -> {@kind_order[row.kind], i} end)

  defp tone_classes(:red), do: "border-red-300 bg-red-50 text-red-800"
  defp tone_classes(:amber), do: "border-amber-300 bg-amber-50 text-amber-800"
  defp tone_classes(:green), do: "border-green-300 bg-green-50 text-green-800"

  defp edge_class(:red), do: "border-l-red-400"
  defp edge_class(:amber), do: "border-l-amber-400"
  defp edge_class(:green), do: "border-l-green-400"

  @doc false
  # Whether Zahlungs and SBI say the same: a refund at SBI is a failure, and
  # a side with no record never matches.
  def same_status?(nil, _theirs), do: false
  def same_status?(_ours, nil), do: false

  def same_status?(%{status: ours}, %{status: theirs}),
    do:
      {ours, theirs} in [
        {"success", :success},
        {"failed", :failed},
        {"failed", :refunded},
        {"processing", :pending}
      ]

  @doc false
  # "selisih +Rp 150": what SBI charged above (or below, with U+2212) the cost
  # recorded here; nil when a side has no cost or they agree.
  def cost_note(%{ours: %{cost: %Decimal{} = ours}, theirs: %{cost: %Decimal{} = theirs}}) do
    diff = Decimal.sub(theirs, ours)

    case Decimal.compare(diff, 0) do
      :eq -> nil
      :gt -> "selisih +" <> format_price(diff)
      :lt -> "selisih −" <> format_price(Decimal.abs(diff))
    end
  end

  def cost_note(_row), do: nil

  defp time(row) do
    case (row.ours && row.ours.inserted_at) || (row.theirs && row.theirs.at) do
      nil -> ""
      at -> at |> LocalTime.to_local() |> Calendar.strftime("%d %b %Y %H:%M")
    end
  end

  defp product(row),
    do: (row.ours && row.ours.product_name) || (row.theirs && row.theirs.product_code) || "-"

  defp customer(row),
    do: (row.ours && row.ours.customer_ref) || (row.theirs && row.theirs.customer_id) || "-"

  defp ours_status(nil), do: "Tidak ada"
  defp ours_status(%{status: "success"}), do: "Berhasil"
  defp ours_status(%{status: "failed"}), do: "Gagal"
  defp ours_status(%{status: _processing}), do: "Diproses"

  defp theirs_status(nil), do: "Tidak ada"
  defp theirs_status(%{status: :success}), do: "Berhasil"
  defp theirs_status(%{status: :failed}), do: "Gagal"
  defp theirs_status(%{status: :refunded}), do: "Refund"
  defp theirs_status(%{status: :pending}), do: "Diproses"

  defp money(nil), do: "-"
  defp money(amount), do: format_price(amount)
end
