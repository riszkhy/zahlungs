defmodule ZahlungsWeb.SupplierLive.FormComponent do
  use ZahlungsWeb, :live_component

  alias Zahlungs.Catalog

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>{@title}</.header>

      <.form
        for={@form}
        id="supplier-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:phone]} type="text" label="Phone" />
        <.input field={@form[:note]} type="text" label="Note" />

        <div class="mt-6">
          <.button phx-disable-with="Saving...">Save Supplier</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{supplier: supplier} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(Catalog.change_supplier(supplier)))}
  end

  @impl true
  def handle_event("validate", %{"supplier" => params}, socket) do
    changeset = Catalog.change_supplier(socket.assigns.supplier, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"supplier" => params}, socket) do
    save_supplier(socket, socket.assigns.action, params)
  end

  defp save_supplier(socket, :edit, params) do
    case Catalog.update_supplier(socket.assigns.supplier, params) do
      {:ok, supplier} ->
        notify_parent({:saved, supplier})

        {:noreply,
         socket
         |> put_flash(:info, "Supplier updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_supplier(socket, :new, params) do
    case Catalog.create_supplier(params) do
      {:ok, supplier} ->
        notify_parent({:saved, supplier})

        {:noreply,
         socket
         |> put_flash(:info, "Supplier created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
