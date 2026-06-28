defmodule ZahlungsWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  These components are built with [Tailwind CSS](https://tailwindcss.com) and a
  [DaisyUI](https://daisyui.com) theme. They are the building blocks used by the
  templates throughout the application — forms, buttons, flash messages, and so on.

  The foundation for styling is Tailwind utility classes; the design tokens
  (`bg-base-100`, `btn`, `alert`, …) come from the project's CSS.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <p
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role="alert"
      class={[
        "alert",
        @kind == :info && "alert-info",
        @kind == :error && "alert-danger"
      ]}
      {@rest}
    >
      <strong :if={@title}>{@title}</strong>
      {msg}
    </p>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def flash_group(assigns) do
    ~H"""
    <div>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.form_wrapper for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.form_wrapper>
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def form_wrapper(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      {render_slot(@inner_block, f)}
      <div :for={action <- @actions} class="flex justify-end mt-6">
        {render_slot(action, f)}
      </div>
    </.form>
    """
  end

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["btn btn-primary phx-submit-loading:opacity-75", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               range search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    # Show errors whenever the underlying changeset has them (i.e. after a submit).
    # We intentionally do not gate on `used_input?/1` so that server-rendered forms
    # surface errors for fields submitted outside the form scope (e.g. the
    # top-level `current_password` param on the settings page).
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={Phoenix.HTML.Form.normalize_value("hidden", @value)} {@rest} />
    """
  end

  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="mt-4">
      <.label for={@id}>{@label}</.label>
      <.password_field id={@id} name={@name} {@rest} />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mt-4">
      <label class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-200">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="form-checkbox"
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mt-4">
      <.label for={@id}>{@label}</.label>
      <select id={@id} name={@name} class="form-control" multiple={@multiple} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mt-4">
      <.label for={@id}>{@label}</.label>
      <textarea id={@id} name={@name} class="form-control" {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mt-4">
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="form-control"
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  A password input with a show/hide toggle.

  Uses a tiny inline-JS toggle (no LiveView hook needed), so it works on the
  controller-rendered auth pages too.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :rest, :global, include: ~w(required placeholder autocomplete minlength maxlength)

  def password_field(assigns) do
    ~H"""
    <div class="relative">
      <input type="password" id={@id} name={@name} class="form-control pr-16" {@rest} />
      <button
        type="button"
        data-target={@id}
        onclick="(function(b){var i=document.getElementById(b.dataset.target);if(!i)return;var s=i.type==='password';i.type=s?'text':'password';b.textContent=s?'Hide':'Show';})(this)"
        tabindex="-1"
        class="absolute inset-y-0 right-0 px-3 text-xs font-medium text-gray-500 hover:text-gray-700"
      >
        Show
      </button>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label
      for={@for}
      class="block text-gray-600 dark:text-gray-200 text-sm font-medium mb-2"
    >
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="block mt-1 text-sm text-red-600">
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-black">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="products" rows={@products}>
        <:col :let={product} label="Name">{product.name}</:col>
        <:col :let={product} label="SKU">{product.sku}</:col>
        <:action :let={product}>
          <.link patch={~p"/products/#{product}/edit"}>Edit</.link>
        </:action>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    ~H"""
    <div id={@id} class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-6 sm:w-full">
        <thead class="text-sm text-left leading-6 text-gray-500">
          <tr>
            <th :for={col <- @col} class="p-2 pb-4 pr-6 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody class="text-sm leading-6 text-gray-700">
          <tr :for={row <- @rows} class="group border-t border-gray-200 hover:bg-gray-50">
            <td :for={col <- @col} class="p-2 pr-6">{render_slot(col, row)}</td>
            <td :if={@action != []} class="p-2">
              <div class="flex gap-3 justify-end">
                <span :for={action <- @action} class="font-semibold leading-6 text-gray-900 hover:text-gray-700">
                  {render_slot(action, row)}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@rows == []} class="mt-6 text-sm text-gray-500">No records found.</p>
    </div>
    """
  end

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal" show on_cancel={JS.navigate(~p"/products")}>
        This is a modal.
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="bg-zinc-50/90 fixed inset-0 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="shadow-zinc-700/10 ring-zinc-700/10 relative hidden rounded-2xl bg-white p-8 shadow-lg ring-1 transition"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-50 hover:opacity-70 text-lg leading-none"
                  aria-label="close"
                >
                  ✕
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## JS Commands

  @doc "Shows a modal by id with a small fade/scale transition."
  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  @doc "Hides a modal by id."
  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-container",
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  @doc """
  Renders the body of a sale receipt: header line, item table and totals.

  Expects a `%Sale{}` preloaded with `:user` and `items: :product`. Used by both
  the cashier (post-sale preview) and the sales history detail so they look
  identical.
  """
  attr :sale, :any, required: true

  def sale_receipt(assigns) do
    ~H"""
    <p class="text-xs text-gray-400">
      {Calendar.strftime(@sale.inserted_at, "%d %b %Y %H:%M")} · {@sale.user && @sale.user.email}
    </p>

    <table class="w-full mt-4 text-sm">
      <thead class="text-left text-gray-500">
        <tr>
          <th class="py-1">Item</th>
          <th class="py-1 text-center">Qty</th>
          <th class="py-1 text-right">Unit</th>
          <th class="py-1 text-right">Line</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={item <- @sale.items} class="border-t border-gray-100">
          <td class="py-1">{(item.product && item.product.name) || "(deleted)"}</td>
          <td class="py-1 text-center">{item.quantity}</td>
          <td class="py-1 text-right">{receipt_money(item.unit_price)}</td>
          <td class="py-1 text-right">{receipt_money(item.line_total)}</td>
        </tr>
      </tbody>
    </table>

    <dl class="mt-4 space-y-1 text-sm border-t border-gray-200 pt-3">
      <div class="flex justify-between"><dt>Subtotal</dt><dd>{receipt_money(@sale.subtotal)}</dd></div>
      <div class="flex justify-between"><dt>Discount</dt><dd>{receipt_money(@sale.discount)}</dd></div>
      <div class="flex justify-between"><dt>Tax</dt><dd>{receipt_money(@sale.tax)}</dd></div>
      <div class="flex justify-between font-semibold"><dt>Total</dt><dd>{receipt_money(@sale.total)}</dd></div>
      <div class="flex justify-between"><dt>Paid</dt><dd>{receipt_money(@sale.amount_paid)}</dd></div>
      <div class="flex justify-between"><dt>Change</dt><dd>{receipt_money(@sale.change_due)}</dd></div>
    </dl>
    """
  end

  defp receipt_money(%Decimal{} = d), do: "Rp " <> Decimal.to_string(d)
  defp receipt_money(other), do: "Rp #{other}"

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ZahlungsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ZahlungsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
