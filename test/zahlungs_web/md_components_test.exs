defmodule ZahlungsWeb.MdComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ZahlungsWeb.MdComponents

  defp slot(text), do: [%{inner_block: fn _, _ -> text end}]

  describe "md_button" do
    test "each variant has its colours and no uppercase" do
      for {variant, class} <- [
            {"filled", "bg-primary"},
            {"tonal", "bg-secondary-container"},
            {"outlined", "border-outline"},
            {"text", "text-primary"},
            {"danger", "bg-error"}
          ] do
        html =
          render_component(&MdComponents.md_button/1,
            variant: variant,
            inner_block: slot("Bayar")
          )

        assert html =~ class, variant
        assert html =~ ~r/>\s*Bayar\s*</
        refute html =~ "uppercase"
      end
    end

    test "passes disabled and phx-disable-with" do
      html =
        render_component(&MdComponents.md_button/1,
          disabled: true,
          "phx-disable-with": "Menyimpan...",
          inner_block: slot("Simpan")
        )

      assert html =~ "disabled"
      assert html =~ ~s(phx-disable-with="Menyimpan...")
    end
  end

  describe "md_chip" do
    test "a selected filter has a check and aria-pressed" do
      on = render_component(&MdComponents.md_chip/1, selected: true, inner_block: slot("Semua"))
      assert on =~ ~s(aria-pressed="true")
      assert on =~ "bg-secondary-container"
      assert on =~ "<svg"

      off = render_component(&MdComponents.md_chip/1, selected: false, inner_block: slot("Semua"))
      assert off =~ ~s(aria-pressed="false")
      assert off =~ "border-outline"
      refute off =~ "<svg"
    end
  end

  describe "md_icon" do
    test "a known name is an svg, an unknown raises" do
      html = render_component(&MdComponents.md_icon/1, name: "camera")
      assert html =~ "<svg"
      assert html =~ ~s(aria-hidden="true")

      assert_raise FunctionClauseError, fn ->
        render_component(&MdComponents.md_icon/1, name: "nope")
      end
    end
  end

  describe "md_search" do
    test "leading search icon, input with the given attributes, trailing slot" do
      html =
        render_component(&MdComponents.md_search/1,
          id: "cashier-scanner",
          name: "q",
          "phx-hook": "BarcodeScanner",
          trailing: slot("TRAIL")
        )

      assert html =~ ~s(id="cashier-scanner")
      assert html =~ ~s(phx-hook="BarcodeScanner")
      assert html =~ ~s(type="search")
      assert html =~ ~r/<svg.*<input[^>]*>.*TRAIL/s
    end
  end

  describe "md_card" do
    test "variants" do
      assert render_component(&MdComponents.md_card/1,
               variant: "outlined",
               inner_block: slot("x")
             ) =~
               "border-outline-variant"

      assert render_component(&MdComponents.md_card/1,
               variant: "elevated",
               inner_block: slot("x")
             ) =~
               "shadow-elev-1"
    end
  end
end
