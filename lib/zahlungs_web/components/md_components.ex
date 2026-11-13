defmodule ZahlungsWeb.MdComponents do
  @moduledoc """
  Material Design 3 components on the MD3 tokens of `assets/css/app.css`
  (Tailwind `bg-primary`, `text-on-surface`, `rounded-md3-*`, `text-title-*`,
  ...). The cashier screen is the first to use them; see
  `docs/superpowers/specs/2026-11-13-kasir-md3-design.md`.

  `CoreComponents` (`<.button>`, `<.modal>`, `<.input>`) stays as it is for the
  other pages.
  """
  use Phoenix.Component

  @doc "A 24px Material icon, in the text colour. An unknown name raises."
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def md_icon(assigns) do
    assigns = assign(assigns, :path, icon_path(assigns.name))

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      width="24"
      height="24"
      fill="currentColor"
      aria-hidden="true"
      class={["inline-block shrink-0", @class]}
    >
      <path d={@path} />
    </svg>
    """
  end

  defp icon_path("search"),
    do:
      "M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"

  defp icon_path("camera"),
    do:
      "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4zM9 2 7.17 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2h-3.17L15 2H9zm3 15c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5z"

  defp icon_path("check"), do: "M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"
  defp icon_path("plus"), do: "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"
  defp icon_path("minus"), do: "M19 13H5v-2h14v2z"

  defp icon_path("close"),
    do:
      "M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"

  defp icon_path("cart"),
    do:
      "M7 18c-1.1 0-1.99.9-1.99 2S5.9 22 7 22s2-.9 2-2-.9-2-2-2zM1 2v2h2l3.6 7.59-1.35 2.45c-.16.28-.25.61-.25.96 0 1.1.9 2 2 2h12v-2H7.42c-.14 0-.25-.11-.25-.25l.03-.12.9-1.63h7.45c.75 0 1.41-.41 1.75-1.03l3.58-6.49A1 1 0 0 0 20 4H5.21l-.94-2H1zm16 16c-1.1 0-1.99.9-1.99 2s.89 2 1.99 2 2-.9 2-2-.9-2-2-2z"

  defp icon_path("history"),
    do:
      "M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42A8.95 8.95 0 0 0 13 21a9 9 0 0 0 0-18zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z"

  defp icon_path("person"),
    do:
      "M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"

  @doc """
  An MD3 button: `filled` (default), `tonal`, `outlined`, `text` or `danger`.
  A pill, 40px high (44px on touch screens), never in capitals.
  """
  attr :variant, :string, default: "filled", values: ~w(filled tonal outlined text danger)
  attr :type, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :icon
  slot :inner_block, required: true

  def md_button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "md-state inline-flex items-center justify-center gap-2 rounded-full h-10 [@media(pointer:coarse)]:h-11 text-label-lg",
        button_variant(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@icon)}
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_variant("filled"), do: "px-6 bg-primary text-on-primary"
  defp button_variant("tonal"), do: "px-6 bg-secondary-container text-on-secondary-container"
  defp button_variant("outlined"), do: "px-6 border border-outline text-primary"
  defp button_variant("text"), do: "px-3 text-primary"
  defp button_variant("danger"), do: "px-6 bg-error text-on-error"

  @doc """
  An MD3 chip. A `filter` chip (default) shows a check and a tonal fill when
  `selected`; an `assist` chip is outlined, with an optional icon.
  """
  attr :kind, :string, default: "filter", values: ~w(filter assist)
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  slot :icon
  slot :inner_block, required: true

  def md_chip(assigns) do
    ~H"""
    <button
      type="button"
      aria-pressed={@kind == "filter" && to_string(@selected)}
      class={[
        "md-state inline-flex shrink-0 items-center gap-2 rounded-md3-sm px-4 text-label-lg",
        "min-h-[44px] [@media(pointer:fine)]:min-h-0 [@media(pointer:fine)]:h-8",
        (@kind == "filter" && @selected && "bg-secondary-container text-on-secondary-container") ||
          "border border-outline text-on-surface-variant",
        @class
      ]}
      {@rest}
    >
      <.md_icon :if={@kind == "filter" && @selected} name="check" class="-ml-1 h-[18px] w-[18px]" />
      {render_slot(@icon)}
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "An MD3 card: `filled` (default), `outlined` or `elevated`."
  attr :variant, :string, default: "filled", values: ~w(filled outlined elevated)
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def md_card(assigns) do
    ~H"""
    <div class={["rounded-md3-md p-4", card_variant(@variant), @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp card_variant("filled"), do: "bg-surface-container-highest"
  defp card_variant("outlined"), do: "border border-outline-variant bg-surface"
  defp card_variant("elevated"), do: "bg-surface-container-low shadow-elev-1"

  @doc """
  An MD3 search bar: a pill with a search icon, the `<input type="search">`
  (every extra attribute, hooks and `phx-*` included, goes on the input) and an
  optional `trailing` slot (an icon button).
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :trailing

  def md_search(assigns) do
    ~H"""
    <div class={[
      "flex min-h-[56px] items-center gap-3 rounded-full bg-surface-container-high px-4 text-on-surface-variant",
      @class
    ]}>
      <.md_icon name="search" />
      <input
        type="search"
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class="min-w-0 flex-1 border-0 bg-transparent p-0 text-body-lg text-on-surface placeholder:text-on-surface-variant focus:ring-0"
        {@rest}
      />
      {render_slot(@trailing)}
    </div>
    """
  end
end
