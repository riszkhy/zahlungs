defmodule ZahlungsWeb.LiveDriver do
  @moduledoc """
  Drives a LiveView through its own callbacks — `mount/3`, `handle_params/3`,
  `handle_event/3`, `render/1` — on a hand-built socket.

  `Phoenix.LiveViewTest.live/2` needs the `lazy_html` package, which this
  project doesn't have yet. Until it does, this is how the behaviour behind a
  LiveView's events gets tested:

      socket =
        CashierLive
        |> mount_live(user)
        |> event("scan", %{"q" => product.sku})
        |> event("checkout")

      assert flash(socket, :info) =~ "completed"
      assert html(socket) =~ "Receipt"

  Not covered here: the router and `on_mount` auth (see the `get/2` access tests
  in each LiveView's test file), JS hooks, and live components (`render/1` of a
  view that is showing one raises). Once `lazy_html` is available, prefer
  `live/2` for new tests.
  """

  alias Phoenix.LiveView.Socket

  @doc """
  Mounts `view` as `user`. Options: `:action` (the live action, default
  `:index`), `:params` (default `%{}`) and `:store` (an admin's store choice: a
  store id or `"all"`; default is the user's own store).
  """
  def mount_live(view, user, opts \\ []) do
    assigns = %{
      __changed__: %{},
      flash: %{},
      live_action: Keyword.get(opts, :action, :index),
      current_user: user,
      current_scope: Zahlungs.Scope.for_user(user, Keyword.get(opts, :store))
    }

    {:ok, socket} =
      view.mount(Keyword.get(opts, :params, %{}), %{}, %Socket{view: view, assigns: assigns})

    handle_params(socket, Keyword.get(opts, :params, %{}))
  end

  @doc "Sends an event, as a `phx-click`/`phx-submit`/`phx-change` would."
  def event(%Socket{view: view} = socket, name, params \\ %{}) do
    {:noreply, socket} = view.handle_event(name, params, reset_transient(socket))
    socket
  end

  @doc "Follows a patch to another live action of the same view, e.g. `/sales/:id`."
  def patch(%Socket{} = socket, action, params \\ %{}) do
    socket = reset_transient(socket)
    handle_params(%{socket | assigns: Map.put(socket.assigns, :live_action, action)}, params)
  end

  @doc "The flash message set by the last event (or by mount), or nil."
  def flash(%Socket{} = socket, kind), do: Phoenix.Flash.get(socket.assigns.flash, kind)

  @doc "Events pushed to the client by the last event, oldest first, as `{name, payload}`."
  def pushed_events(%Socket{} = socket) do
    (socket.private.live_temp[:push_events] || [])
    |> Enum.reverse()
    |> Enum.map(fn [name, payload | _] -> {name, payload} end)
  end

  @doc "The path the last event patched or navigated to, or nil."
  def live_redirect(%Socket{redirected: {:live, _kind, %{to: to}}}), do: to
  def live_redirect(%Socket{}), do: nil

  @doc "Renders the view with its current assigns."
  def html(%Socket{view: view, assigns: assigns} = socket) do
    assigns
    |> Map.merge(%{__changed__: nil, socket: socket})
    |> view.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp handle_params(%Socket{view: view} = socket, params) do
    if function_exported?(view, :handle_params, 3) do
      {:noreply, socket} = view.handle_params(params, "http://localhost/", socket)
      socket
    else
      socket
    end
  end

  # Flash, pushed events and redirects describe the outcome of one event, so
  # they are cleared before the next one.
  defp reset_transient(%Socket{} = socket) do
    %{
      socket
      | redirected: nil,
        private: Map.put(socket.private, :live_temp, %{}),
        assigns: Map.put(socket.assigns, :flash, %{})
    }
  end
end
