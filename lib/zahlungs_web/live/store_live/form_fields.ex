defmodule ZahlungsWeb.StoreLive.FormFields do
  @moduledoc """
  The inputs for a store's own data, shared by the edit modal
  (`StoreLive.Index`) and step 1 of the branch registration wizard
  (`StoreLive.Register`). The form must be named `store`: the `StoreLocation`
  hook looks the coordinate inputs up by that name.
  """
  use ZahlungsWeb, :html

  attr :form, Phoenix.HTML.Form, required: true

  attr :deposit_account_options, :list,
    default: [],
    doc: "active deposit accounts as `{name, id}`, for the PPOB services the store sells"

  def store_fields(assigns) do
    ~H"""
    <.input field={@form[:name]} type="text" label="Nama" required />
    <.input field={@form[:code]} type="text" label="Kode (awalan nomor invoice)" required />
    <.input field={@form[:address]} type="text" label="Alamat (tampil di struk)" />
    <.input field={@form[:phone]} type="text" label="Telepon" />
    <.input
      field={@form[:utc_offset_hours]}
      type="select"
      label="Zona waktu"
      options={[{"WIB (UTC+7)", 7}, {"WITA (UTC+8)", 8}, {"WIT (UTC+9)", 9}]}
    />
    <.input
      field={@form[:deposit_account_id]}
      type="select"
      label="Akun deposit (untuk layanan PPOB)"
      prompt="— Belum ada —"
      options={@deposit_account_options}
    />

    <div id="store-location" phx-hook="StoreLocation" class="mt-2 grid grid-cols-2 gap-3">
      <.input field={@form[:latitude]} type="text" label="Latitude" inputmode="decimal" />
      <.input field={@form[:longitude]} type="text" label="Longitude" inputmode="decimal" />
      <p class="col-span-2 text-xs text-gray-500">
        Opsional. Dipakai untuk menampilkan jarak login dari toko.
        <button type="button" data-use-my-location class="underline">Pakai lokasi saya sekarang</button>
      </p>
    </div>
    """
  end
end
