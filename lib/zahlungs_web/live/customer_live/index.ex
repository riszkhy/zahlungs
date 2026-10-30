defmodule ZahlungsWeb.CustomerLive.Index do
  @moduledoc """
  Customers who may buy on credit (piutang), admin only: what each owes, their
  credit limit, and the form to add or change one. The limit is set only here;
  a customer added at the cashier starts at 0.
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Customers
  alias Zahlungs.Customers.Customer

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:q, "") |> load_customers()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Pelanggan")
    |> assign(customer: nil, form: nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Pelanggan baru")
    |> put_form(%Customer{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Ubah pelanggan")
    |> put_form(Customers.get_customer!(id))
  end

  defp put_form(socket, customer, changeset \\ nil) do
    changeset = changeset || Customers.change_customer(socket.assigns.current_user, customer)
    assign(socket, customer: customer, form: to_form(changeset))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:q, q) |> load_customers()}
  end

  def handle_event("save", %{"customer" => params}, socket) do
    user = socket.assigns.current_user

    result =
      case socket.assigns.customer do
        %Customer{id: nil} -> Customers.create_customer(user, params)
        customer -> Customers.update_customer(user, customer, params)
      end

    case result do
      {:ok, _customer} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pelanggan disimpan.")
         |> load_customers()
         |> push_patch(to: ~p"/admin/customers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_form(socket, socket.assigns.customer, changeset)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Hanya admin yang bisa mengubah pelanggan.")}
    end
  end

  defp load_customers(socket) do
    rows =
      Enum.map(
        Customers.list_customers(q: socket.assigns.q),
        &%{customer: &1, balance: Customers.balance(&1)}
      )

    assign(socket, :rows, rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Pelanggan
      <:subtitle>Pelanggan yang boleh berutang (piutang) dan limitnya (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/reports/receivables"} class="btn btn-sm btn-link">Laporan piutang</.link>
        <.link patch={~p"/admin/customers/new"}>
          <.button>Pelanggan baru</.button>
        </.link>
      </:actions>
    </.header>

    <form phx-change="search" phx-submit="search" class="mt-4">
      <input
        type="search"
        name="q"
        value={@q}
        placeholder="Cari nama atau no HP"
        phx-debounce="300"
        class="form-control"
      />
    </form>

    <.table id="customers" rows={@rows}>
      <:col :let={row} label="Nama">
        <.link navigate={~p"/admin/customers/#{row.customer.id}"} class="text-green-700 hover:underline">
          {row.customer.name}
        </.link>
        <span :if={not row.customer.active} class="ml-1 text-xs text-gray-500">(nonaktif)</span>
      </:col>
      <:col :let={row} label="No HP">{row.customer.phone || "—"}</:col>
      <:col :let={row} label="Utang">
        <span class={Decimal.gt?(row.balance, 0) && "font-semibold text-red-700"}>
          {format_money(row.balance)}
        </span>
      </:col>
      <:col :let={row} label="Limit">{format_money(row.customer.credit_limit)}</:col>
      <:action :let={row}>
        <.link patch={~p"/admin/customers/#{row.customer.id}/edit"}>Ubah</.link>
      </:action>
    </.table>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="customer-modal"
      show
      on_cancel={JS.patch(~p"/admin/customers")}
    >
      <.header>{@page_title}</.header>

      <.form for={@form} id="customer-form" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Nama" required />
        <.input field={@form[:phone]} type="text" label="No HP" />
        <.input field={@form[:note]} type="text" label="Catatan" />
        <.input
          field={@form[:credit_limit]}
          type="number"
          label="Limit piutang (0 = tidak boleh berutang)"
          min="0"
          step="1"
        />
        <.input field={@form[:active]} type="checkbox" label="Aktif (boleh berutang)" />

        <div class="mt-6">
          <.button phx-disable-with="Menyimpan...">Simpan</.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
