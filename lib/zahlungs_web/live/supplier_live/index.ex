defmodule ZahlungsWeb.SupplierLive.Index do
  @moduledoc """
  Admin supplier (consignor) management (CRUD). Admin-only via the router's admin
  live_session. Suppliers own consignment products (titip jual).
  """
  use ZahlungsWeb, :live_view

  alias Zahlungs.Catalog
  alias Zahlungs.Catalog.Supplier

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_suppliers(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Suppliers")
    |> assign(:supplier, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Supplier")
    |> assign(:supplier, %Supplier{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Supplier")
    |> assign(:supplier, Catalog.get_supplier!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    supplier = Catalog.get_supplier!(id)
    {:ok, _} = Catalog.delete_supplier(supplier)

    {:noreply,
     socket
     |> put_flash(:info, "Supplier deleted")
     |> load_suppliers()}
  end

  @impl true
  def handle_info({ZahlungsWeb.SupplierLive.FormComponent, {:saved, _supplier}}, socket) do
    {:noreply, load_suppliers(socket)}
  end

  defp load_suppliers(socket) do
    assign(socket, :suppliers, Catalog.list_suppliers())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Suppliers
      <:subtitle>Kelola pemilik barang titipan / konsinyasi (khusus admin)</:subtitle>
      <:actions>
        <.link navigate={~p"/reports/consignment"} class="btn btn-sm btn-link">Settlement</.link>
        <.link patch={~p"/admin/suppliers/new"}>
          <.button>New Supplier</.button>
        </.link>
      </:actions>
    </.header>

    <.table id="suppliers" rows={@suppliers}>
      <:col :let={supplier} label="Name">{supplier.name}</:col>
      <:col :let={supplier} label="Phone">{supplier.phone || "—"}</:col>
      <:col :let={supplier} label="Note">{supplier.note || "—"}</:col>
      <:action :let={supplier}>
        <.link patch={~p"/admin/suppliers/#{supplier}/edit"}>Edit</.link>
      </:action>
      <:action :let={supplier}>
        <.link
          phx-click={JS.push("delete", value: %{id: supplier.id})}
          data-confirm="Delete this supplier?"
        >
          Delete
        </.link>
      </:action>
    </.table>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="supplier-modal"
      show
      on_cancel={JS.patch(~p"/admin/suppliers")}
    >
      <.live_component
        module={ZahlungsWeb.SupplierLive.FormComponent}
        id={@supplier.id || :new}
        title={@page_title}
        action={@live_action}
        supplier={@supplier}
        patch={~p"/admin/suppliers"}
      />
    </.modal>
    """
  end
end
