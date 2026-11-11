defmodule ZahlungsWeb.DepositLive.Reconcile do
  @moduledoc """
  Reconciling one deposit account's api services with SBI's transaction
  history for one day (`Services.reconcile/3`), admin only. SBI is asked only
  when the admin presses Cocokkan, never on opening the page. A row's button
  asks SBI about that service again (`Services.recheck_row/2`, which never
  sends a payment) and updates that row only.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.{Deposits, LocalTime, Services}

  @kind_labels %{
    follow: "Ikuti SBI",
    conflict: "Bertentangan",
    pending_there: "Belum final di SBI",
    ours_only: "Hanya di Zahlungs",
    cost_diff: "Selisih modal",
    theirs_only: "Hanya di SBI",
    matched: "Cocok"
  }

  @buttons %{
    follow: "Ikuti SBI",
    conflict: "Tinjau",
    pending_there: "Cek status",
    ours_only: "Cek status"
  }

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
     |> assign(rows: nil, summary: nil, error: nil, show_matched: false)}
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
        indexed: if(assigns.rows, do: Enum.with_index(assigns.rows), else: []),
        kinds: Services.Reconciliation.kinds(),
        kind_labels: @kind_labels
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
        <span :for={kind <- @kinds} class="rounded-full border border-gray-200 px-3 py-1">
          {@kind_labels[kind]} <strong>{@summary.counts[kind]}</strong>
        </span>
      </div>
      <dl class="flex flex-wrap gap-x-6 gap-y-1 text-sm">
        <div><dt class="inline text-gray-600">Selisih modal</dt> <dd class="inline font-medium">{format_price(@summary.cost_difference)}</dd></div>
        <div><dt class="inline text-gray-600">Potongan tanpa transaksi Zahlungs</dt> <dd class="inline font-medium">{format_price(@summary.theirs_only_total)}</dd></div>
      </dl>

      <p :if={@rows == []} class="text-sm text-gray-600">Tidak ada transaksi pada tanggal ini.</p>

      <ul class="space-y-3">
        <.row_card :for={{row, index} <- @indexed} :if={row.kind != :matched} row={row} index={index} />
      </ul>

      <div :if={@summary.counts.matched > 0}>
        <button type="button" phx-click="toggle_matched" class="chip">
          {if @show_matched,
            do: "Sembunyikan yang cocok",
            else: "Lihat yang cocok (#{@summary.counts.matched})"}
        </button>
        <ul :if={@show_matched} class="mt-3 space-y-3">
          <.row_card :for={{row, index} <- @indexed} :if={row.kind == :matched} row={row} index={index} />
        </ul>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :index, :integer, required: true

  defp row_card(assigns) do
    assigns =
      assign(assigns,
        label: @kind_labels[assigns.row.kind],
        button: if(assigns.row.ours && not assigns.row.in_review?, do: @buttons[assigns.row.kind])
      )

    ~H"""
    <li id={"reconcile-row-#{@index}"} class="rounded-lg border border-gray-200 p-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium">{@label}</span>
          <span :if={@row.in_review?} class="rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">Sedang ditinjau</span>
        </div>
        <span class="text-sm text-gray-500">{time(@row)}</span>
      </div>
      <p class="mt-2 min-w-0 break-words font-medium">{(@row.ours && @row.ours.code) || @row.ref || "Tanpa ref"}</p>
      <p :if={@row.ours && @row.ref} class="min-w-0 break-words text-xs text-gray-500">{@row.ref}</p>
      <p class="min-w-0 break-words text-sm text-gray-600">{product(@row)} · {customer(@row)}</p>
      <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <div class="min-w-0"><dt class="text-gray-500">Di Zahlungs</dt><dd>{ours_status(@row.ours)}</dd></div>
        <div class="min-w-0"><dt class="text-gray-500">Di SBI</dt><dd>{theirs_status(@row.theirs)}</dd></div>
        <div class="min-w-0"><dt class="text-gray-500">Modal</dt><dd>{money(@row.ours && @row.ours.cost)}</dd></div>
        <div class="min-w-0"><dt class="text-gray-500">Potongan SBI</dt><dd>{money(@row.theirs && @row.theirs.cost)}</dd></div>
      </dl>
      <button :if={@button} type="button" phx-click="recheck" phx-value-index={@index} phx-disable-with="Menanyakan SBI..." class="chip mt-3">{@button}</button>
    </li>
    """
  end

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
