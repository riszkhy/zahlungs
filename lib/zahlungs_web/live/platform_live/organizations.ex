defmodule ZahlungsWeb.PlatformLive.Organizations do
  @moduledoc """
  The platform operator's review page: every organization that signed up, with
  its owner and size. Approve or reject a pending one, suspend or reactivate an
  active one, and keep the manual billing record (paid-until date and a note).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Organizations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Organisasi", status: "") |> load()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  def handle_event("set_status", %{"organization_id" => id, "status" => status} = params, socket) do
    organization = Organizations.get_organization!(id)
    note = blank_to_nil(params["note"])

    case Organizations.set_status(organization, status, socket.assigns.current_user, note) do
      {:ok, updated} ->
        {:noreply, socket |> put_flash(:info, status_message(updated)) |> load()}

      {:error, :invalid_transition} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Status #{organization.name} tidak bisa diubah dari #{organization.status} ke #{status}."
         )}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Catatan terlalu panjang (maksimal 255 karakter).")}
    end
  end

  def handle_event("save_billing", %{"organization_id" => id, "billing" => attrs}, socket) do
    organization = Organizations.get_organization!(id)

    case Organizations.update_billing(organization, attrs) do
      {:ok, updated} ->
        {:noreply, socket |> put_flash(:info, "Tagihan #{updated.name} disimpan.") |> load()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Tanggal atau catatan tagihan tidak valid.")}
    end
  end

  defp load(socket) do
    assign(socket, :rows, Organizations.list_organizations(status: socket.assigns.status))
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp status_message(%{status: "active", name: name}), do: "#{name} disetujui dan aktif."
  defp status_message(%{status: "suspended", name: name}), do: "#{name} ditangguhkan."
  defp status_message(%{status: "rejected", name: name}), do: "#{name} ditolak."

  # What the operator can do next, as {status, label} pairs.
  defp actions("pending"), do: [{"active", "Setujui"}, {"rejected", "Tolak"}]
  defp actions("active"), do: [{"suspended", "Tangguhkan"}]
  defp actions("suspended"), do: [{"active", "Aktifkan lagi"}]
  defp actions("rejected"), do: [{"active", "Setujui"}]

  defp status_label("pending"), do: "Menunggu"
  defp status_label("active"), do: "Aktif"
  defp status_label("suspended"), do: "Ditangguhkan"
  defp status_label("rejected"), do: "Ditolak"

  defp status_class("pending"), do: "bg-yellow-100 text-yellow-800"
  defp status_class("active"), do: "bg-green-100 text-green-700"
  defp status_class("suspended"), do: "bg-red-100 text-red-700"
  defp status_class("rejected"), do: "bg-gray-200 text-gray-700"

  defp overdue?(%{status: "active", paid_until: %Date{} = date}),
    do: Date.compare(date, Zahlungs.LocalTime.today()) == :lt

  defp overdue?(_organization), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Organisasi
      <:subtitle>
        Pendaftar baru menunggu persetujuan di sini. Penagihan dicatat manual.
      </:subtitle>
    </.header>

    <form phx-change="filter" class="mt-6">
      <label class="text-sm">
        Status
        <select name="status" class="form-control">
          <option value="" selected={@status == ""}>Semua</option>
          <option :for={status <- Organizations.Organization.statuses()} value={status} selected={@status == status}>
            {status_label(status)}
          </option>
        </select>
      </label>
    </form>

    <div class="mt-4 space-y-4">
      <div :for={row <- @rows} id={"organization-#{row.organization.id}"} class="rounded-lg border border-gray-200 p-4">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="min-w-0">
            <p class="font-semibold">{row.organization.name}</p>
            <p class="text-sm text-gray-600">
              {row.owner_email || "—"}
              <span :if={row.organization.phone}>· {row.organization.phone}</span>
            </p>
            <p class="text-xs text-gray-500">
              {row.stores} toko · {row.users} user · daftar
              {Calendar.strftime(Zahlungs.LocalTime.to_local(row.organization.inserted_at), "%d %b %Y")}
            </p>
            <p :if={row.organization.review_note} class="mt-1 text-xs text-gray-500">
              Catatan: {row.organization.review_note}
            </p>
          </div>
          <span class={["rounded-full px-2 py-0.5 text-xs", status_class(row.organization.status)]}>
            {status_label(row.organization.status)}
          </span>
        </div>

        <form phx-submit="set_status" class="mt-3 flex flex-wrap items-end gap-2">
          <input type="hidden" name="organization_id" value={row.organization.id} />
          <label class="min-w-0 flex-1 text-xs text-gray-600">
            Catatan (opsional)
            <input type="text" name="note" maxlength="255" class="form-control" />
          </label>
          <button
            :for={{status, label} <- actions(row.organization.status)}
            type="submit"
            name="status"
            value={status}
            class="chip"
          >
            {label}
          </button>
        </form>

        <form phx-submit="save_billing" class="mt-3 flex flex-wrap items-end gap-2 border-t border-gray-100 pt-3">
          <input type="hidden" name="organization_id" value={row.organization.id} />
          <label class="text-xs text-gray-600">
            Dibayar sampai
            <input
              type="date"
              name="billing[paid_until]"
              value={row.organization.paid_until}
              class="form-control"
            />
          </label>
          <label class="min-w-0 flex-1 text-xs text-gray-600">
            Catatan tagihan
            <input
              type="text"
              name="billing[billing_note]"
              value={row.organization.billing_note}
              maxlength="255"
              class="form-control"
            />
          </label>
          <button type="submit" class="chip">Simpan tagihan</button>
          <span :if={overdue?(row.organization)} class="text-xs font-medium text-red-700">
            Jatuh tempo lewat
          </span>
        </form>
      </div>
      <p :if={@rows == []} class="text-sm text-gray-500">Tidak ada organisasi dengan status ini.</p>
    </div>
    """
  end
end
