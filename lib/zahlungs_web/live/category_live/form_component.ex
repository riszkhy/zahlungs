defmodule ZahlungsWeb.CategoryLive.FormComponent do
  use ZahlungsWeb, :live_component

  alias Zahlungs.Catalog

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>{@title}</.header>

      <.form
        for={@form}
        id="category-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" required />

        <div class="mt-6">
          <.button phx-disable-with="Saving...">Save Category</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{category: category} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(Catalog.change_category(category)))}
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    changeset = Catalog.change_category(socket.assigns.category, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    save_category(socket, socket.assigns.action, params)
  end

  defp save_category(socket, :edit, params) do
    case Catalog.update_category(socket.assigns.category, params) do
      {:ok, category} ->
        notify_parent({:saved, category})

        {:noreply,
         socket
         |> put_flash(:info, "Category updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_category(socket, :new, params) do
    case Catalog.create_category(params) do
      {:ok, category} ->
        notify_parent({:saved, category})

        {:noreply,
         socket
         |> put_flash(:info, "Category created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
