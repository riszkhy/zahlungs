defmodule ZahlungsWeb.PageHTML do
  @moduledoc """
  The landing page at `/`, and the contact details it shows (set under
  `config :zahlungs, :contact`).
  """
  use ZahlungsWeb, :html

  embed_templates "page_html/*"

  @doc "The address people write to."
  def contact_email, do: contact(:email)

  @doc "A WhatsApp link to the contact number, with an opening message."
  def whatsapp_url(message \\ "Halo, saya tertarik dengan Zahlungs.") do
    "https://wa.me/#{contact(:whatsapp)}?text=#{URI.encode_www_form(message)}"
  end

  @doc "The contact number as people read it: `+62 897 8844 555`."
  def whatsapp_label do
    case contact(:whatsapp) do
      "62" <> rest ->
        groups = rest |> String.graphemes() |> chunk_number()
        "+62 " <> Enum.join(groups, " ")

      other ->
        other
    end
  end

  # 8978844555 -> ["897", "8844", "555"]: three digits, then fours, the rest last.
  defp chunk_number(digits) do
    {head, tail} = Enum.split(digits, 3)
    [Enum.join(head) | tail |> Enum.chunk_every(4) |> Enum.map(&Enum.join/1)]
  end

  defp contact(key), do: :zahlungs |> Application.fetch_env!(:contact) |> Keyword.fetch!(key)

  # The cashier screen, drawn: a tablet showing category chips, product tiles
  # and a cart. An illustration for the page, not a screenshot, so it carries
  # no shop's real data.
  @tiles [
    {"Kopi susu", "18.000"},
    {"Teh botol", "5.000"},
    {"Mie instan", "3.500"},
    {"Roti tawar", "16.000"},
    {"Air mineral", "4.000"},
    {"Gula 1 kg", "17.500"}
  ]

  @cart [
    {"Kopi susu", 2, "36.000"},
    {"Mie instan", 3, "10.500"},
    {"Air mineral", 1, "4.000"}
  ]

  attr :class, :string, default: nil

  def cashier_mock(assigns) do
    assigns = assign(assigns, tiles: @tiles, cart: @cart)

    ~H"""
    <figure class={["mx-auto w-full max-w-xl", @class]}>
      <div class="rounded-[1.75rem] bg-gray-800 p-2.5 shadow-xl" aria-hidden="true">
        <div class="overflow-hidden rounded-2xl bg-green-50">
          <div class="flex items-center gap-3 bg-green-700 px-4 py-2 text-xs text-white">
            <span class="font-bold">Zahlungs</span>
            <span class="opacity-80">Cashier</span>
            <span class="opacity-80">Sales</span>
            <span class="opacity-80">Shifts</span>
            <span class="ml-auto rounded bg-white/15 px-2 py-0.5">Toko Utama</span>
          </div>

          <div class="grid grid-cols-5 gap-3 p-3">
            <div class="col-span-3">
              <div class="flex gap-1.5 text-[10px]">
                <span class="rounded-full bg-green-700 px-2.5 py-1 text-white">Semua</span>
                <span class="rounded-full border border-gray-300 bg-white px-2.5 py-1 text-gray-600">Minuman</span>
                <span class="hidden rounded-full border border-gray-300 bg-white px-2.5 py-1 text-gray-600 sm:inline">
                  Makanan
                </span>
              </div>
              <div class="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
                <div :for={{name, price} <- @tiles} class="rounded-lg border border-gray-200 bg-white p-2 text-[11px] shadow-sm">
                  <p class="font-medium text-gray-800">{name}</p>
                  <p class="mt-1 text-gray-500">Rp {price}</p>
                </div>
              </div>
            </div>

            <div class="col-span-2 flex flex-col rounded-lg border border-gray-200 bg-white p-2.5 text-[11px]">
              <p class="font-semibold text-gray-700">Keranjang</p>
              <ul class="mt-2 flex-1 space-y-1.5">
                <li :for={{name, qty, total} <- @cart} class="flex justify-between gap-2 text-gray-700">
                  <span class="truncate">{name} ×{qty}</span>
                  <span class="shrink-0">{total}</span>
                </li>
              </ul>
              <div class="mt-2 flex justify-between border-t border-gray-200 pt-2 font-semibold text-gray-800">
                <span>Total</span>
                <span>Rp 50.500</span>
              </div>
              <div class="mt-2 rounded bg-green-700 py-1.5 text-center font-medium text-white">Bayar</div>
            </div>
          </div>
        </div>
      </div>
      <figcaption class="mt-2 text-center text-xs text-gray-500">Ilustrasi layar kasir</figcaption>
    </figure>
    """
  end
end
