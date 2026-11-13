defmodule ZahlungsWeb.MdTokensTest do
  use ExUnit.Case, async: true

  @css File.read!("assets/css/app.css")
  @config File.read!("assets/tailwind.config.js")

  @roles %{
    "primary" => "#016D30",
    "on-primary" => "#FFFFFF",
    "primary-container" => "#ABF3B8",
    "on-primary-container" => "#002106",
    "secondary" => "#4C6450",
    "secondary-container" => "#CEEAD2",
    "on-secondary-container" => "#0A200E",
    "tertiary" => "#006971",
    "error" => "#BA1A1A",
    "error-container" => "#FFDAD6",
    "warning" => "#914D00",
    "warning-container" => "#FFDCC2",
    "on-warning-container" => "#2B1700",
    "surface" => "#F4FBF5",
    "surface-container-lowest" => "#FFFFFF",
    "surface-container-low" => "#EEF5EF",
    "surface-container" => "#E9F0E9",
    "surface-container-high" => "#E3EAE4",
    "surface-container-highest" => "#DDE4DE",
    "on-surface" => "#181D19",
    "on-surface-variant" => "#3E4A40",
    "outline" => "#6E7A6F",
    "outline-variant" => "#BDCABE"
  }

  test "every role is a CSS variable with the spec's value" do
    for {role, hex} <- @roles, do: assert(@css =~ "--md-#{role}: #{hex};", role)
  end

  test "Tailwind names each role after its variable" do
    for {role, _hex} <- @roles, do: assert(@config =~ "'#{role}': 'var(--md-#{role})'", role)
  end

  test "shapes, elevation, type and the state layer" do
    for name <-
          ~w(md3-xs md3-sm md3-md md3-lg md3-xl elev-1 elev-2 elev-3 title-lg label-lg headline-sm),
        do: assert(@config =~ "'#{name}'", name)

    assert @css =~ ".md3 {"
    assert @css =~ "Roboto, system-ui, sans-serif"
    assert @css =~ ".md-state::before"
  end
end
