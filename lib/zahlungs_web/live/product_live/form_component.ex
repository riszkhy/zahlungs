defmodule ZahlungsWeb.ProductLive.FormComponent do
  use ZahlungsWeb, :live_component

  alias Zahlungs.Catalog

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>{@title}</.header>

      <.form
        for={@form}
        id="product-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:sku]} type="text" label="SKU" required />
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <.input field={@form[:price]} type="number" label="Price" step="0.01" min="0" required />
          <.input field={@form[:stock]} type="number" label="Stock" min="0" required />
        </div>

        <.input
          field={@form[:category_id]}
          type="select"
          label="Category"
          prompt="— none —"
          options={@category_options}
        />
        <.input field={@form[:image_url]} type="text" label="Image URL" />
        <.input field={@form[:active]} type="checkbox" label="Active" />

        <div class="mt-6">
          <.button phx-disable-with="Saving...">Save Product</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{product: product} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:category_options, Catalog.category_options())
     |> assign(:form, to_form(Catalog.change_product(product)))}
  end

  @impl true
  def handle_event("validate", %{"product" => params}, socket) do
    changeset = Catalog.change_product(socket.assigns.product, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"product" => params}, socket) do
    save_product(socket, socket.assigns.action, params)
  end

  defp save_product(socket, :edit, params) do
    case Catalog.update_product(socket.assigns.product, params) do
      {:ok, product} ->
        notify_parent({:saved, product})

        {:noreply,
         socket
         |> put_flash(:info, "Product updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_product(socket, :new, params) do
    case Catalog.create_product(params) do
      {:ok, product} ->
        notify_parent({:saved, product})

        {:noreply,
         socket
         |> put_flash(:info, "Product created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
