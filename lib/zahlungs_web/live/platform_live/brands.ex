defmodule ZahlungsWeb.PlatformLive.Brands do
  @moduledoc """
  The platform operator's "Awalan nomor" page: the mobile number prefixes
  that name each brand on every organization's cashier screen (pulsa and
  paket data). Saved all at once; a wrong or shared prefix is shown at its
  brand and nothing is saved. "Kembalikan bawaan" puts the defaults back.

  A cashier screen already open keeps the prefixes it loaded until it is
  opened again.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Services
  alias Zahlungs.Services.Brand

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Awalan nomor", errors: %{})
     |> assign(:values, values(Services.brand_prefixes()))}
  end

  @impl true
  def handle_event("save", %{"prefixes" => params}, socket) do
    case Services.save_brand_prefixes(params) do
      {:ok, prefixes} ->
        {:noreply,
         socket
         |> assign(values: values(prefixes), errors: %{})
         |> put_flash(:info, "Awalan nomor disimpan.")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(values: Map.take(params, Brand.keys()), errors: errors)
         |> put_flash(:error, "Awalan nomor belum disimpan. Periksa isian yang ditandai.")}
    end
  end

  def handle_event("reset", _params, socket) do
    {:ok, prefixes} = Services.reset_brand_prefixes()

    {:noreply,
     socket
     |> assign(values: values(prefixes), errors: %{})
     |> put_flash(:info, "Awalan nomor kembali ke bawaan.")}
  end

  defp values(prefixes),
    do: Map.new(prefixes, fn {brand, list} -> {brand, Enum.join(list, ", ")} end)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Awalan nomor
      <:subtitle>
        Empat angka pertama nomor HP yang menandai brand di layar Layanan (pulsa dan paket data), untuk semua organisasi.
        Nomor by.U memakai awalan Telkomsel, jadi biasanya dikosongkan.
      </:subtitle>
    </.header>

    <form id="brand-prefixes" phx-submit="save" class="mt-6 max-w-2xl space-y-4">
      <div :for={{label, brand} <- Brand.options()}>
        <label class="block text-sm font-medium text-gray-700" for={"prefixes-#{brand}"}>{label}</label>
        <input
          type="text"
          id={"prefixes-#{brand}"}
          name={"prefixes[#{brand}]"}
          value={@values[brand]}
          class={["form-control", @errors[brand] && "!border-red-500"]}
          autocomplete="off"
          placeholder="mis. 0811, 0812"
        />
        <p :if={@errors[brand]} class="mt-1 text-sm text-red-600">{@errors[brand]}</p>
      </div>

      <div class="flex flex-wrap gap-2">
        <button type="submit" phx-disable-with="Menyimpan..." class="btn btn-primary">Simpan</button>
        <button
          type="button"
          phx-click="reset"
          data-confirm="Kembalikan semua awalan ke daftar bawaan?"
          class="chip"
        >
          Kembalikan bawaan
        </button>
      </div>
    </form>
    """
  end
end
