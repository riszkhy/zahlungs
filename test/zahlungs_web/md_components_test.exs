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

  describe "md_segmented" do
    test "one radio per option, the chosen checked, a disabled one inert" do
      html =
        render_component(&MdComponents.md_segmented/1,
          name: "payment_method",
          value: "qris",
          options: [{"cash", "Tunai"}, {"qris", "QRIS"}, {"credit", "Piutang"}],
          disabled_options: ["credit"],
          event: "set_payment_method",
          value_key: :method
        )

      assert html =~ ~s(role="radiogroup")
      assert length(Regex.scan(~r/type="radio"[^>]*name="payment_method"/, html)) == 3
      assert html =~ ~r/<input[^>]*value="qris"[^>]*checked/
      assert html =~ ~r/<input[^>]*value="credit"[^>]*disabled/
      refute html =~ ~r/<input[^>]*value="credit"[^>]*phx-click/
      assert html =~ ~r/<input[^>]*value="qris"[^>]*phx-click="[^"]*set_payment_method/
    end
  end

  describe "md_text_field" do
    test "keeps id, hook and phx-update" do
      html =
        render_component(&MdComponents.md_text_field/1,
          id: "amount-paid",
          name: "amount_paid",
          value: "",
          label: "Uang diterima",
          "phx-hook": "MoneyInput",
          "phx-update": "ignore"
        )

      assert html =~ ~s(id="amount-paid")
      assert html =~ ~s(phx-hook="MoneyInput")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "Uang diterima"
      assert html =~ "rounded-md3-xs"
    end

    test "select" do
      html =
        render_component(&MdComponents.md_text_field/1,
          name: "category",
          type: "select",
          label: "Tipe",
          options: [{"Masuk", "in"}, {"Keluar", "out"}],
          value: "in"
        )

      assert html =~ ~s(<select)
      assert html =~ ~r/value="in"[^>]*selected|selected[^>]*value="in"/
    end
  end

  describe "md_dialog" do
    test "ids and close mark like modal" do
      html =
        render_component(&MdComponents.md_dialog/1,
          id: "confirm-sale",
          title: slot("Konfirmasi penjualan"),
          inner_block: slot("BODY"),
          actions: slot("ACTIONS")
        )

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(id="confirm-sale-container")
      assert html =~ ~s(id="confirm-sale-bg")
      assert html =~ ~r/aria-label="close".*id="confirm-sale-content"/s
      assert html =~ ~r/id="confirm-sale-title"[^>]*>\s*Konfirmasi penjualan/
      assert html =~ ~r/id="confirm-sale-content".*BODY.*ACTIONS/s
      assert html =~ "rounded-md3-xl"
    end
  end

  describe "md_sheet" do
    test "closed hides on phones, open has a scrim that closes" do
      closed =
        render_component(&MdComponents.md_sheet/1,
          id: "cart-sheet",
          open: false,
          on_close: "toggle_cart",
          inner_block: slot("CART")
        )

      assert closed =~ "hidden lg:block"
      refute closed =~ "bg-black/30"

      open =
        render_component(&MdComponents.md_sheet/1,
          id: "cart-sheet",
          open: true,
          on_close: "toggle_cart",
          inner_block: slot("CART")
        )

      assert open =~
               ~r/bg-black\/30[^>]*phx-click="toggle_cart"|phx-click="toggle_cart"[^>]*bg-black\/30/

      assert open =~ "rounded-t-md3-xl"
      assert open =~ "CART"
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

  describe "md_button as a link" do
    test "navigate renders a link with the variant's classes" do
      html =
        render_component(&MdComponents.md_button/1,
          variant: "outlined",
          navigate: "/services/history",
          inner_block: slot("Lihat semua riwayat")
        )

      assert html =~ ~r/<a[^>]*href="\/services\/history"/
      assert html =~ "border-outline"
      refute html =~ "<button"
    end

    test "href with target opens a new tab" do
      html =
        render_component(&MdComponents.md_button/1,
          variant: "text",
          href: "/sales/1/receipt",
          target: "_blank",
          rel: "noopener",
          inner_block: slot("Print receipt")
        )

      [tag] = Regex.run(~r/<a[^>]*>/, html)
      assert tag =~ ~s(href="/sales/1/receipt")
      assert tag =~ ~s(target="_blank")
      assert tag =~ ~s(rel="noopener")
    end
  end

  describe "md_text_field extras" do
    test "a textarea keeps its name, value and rows" do
      html =
        render_component(&MdComponents.md_text_field/1,
          type: "textarea",
          name: "reason",
          value: "Salah nomor",
          rows: "2",
          label: "Alasan"
        )

      assert html =~
               ~r/<textarea[^>]*name="reason"[^>]*rows="2"[^>]*>\s*Salah nomor\s*<\/textarea>/
    end

    test "the trailing slot sits inside the field" do
      html =
        render_component(&MdComponents.md_text_field/1,
          name: "n",
          value: "0812",
          trailing: slot("✕")
        )

      assert html =~ ~r/<input[^>]*pr-12[^>]*>.*✕/s
    end
  end

  describe "md_badge" do
    test "each tone has its colours" do
      for {tone, class} <- [
            {"success", "bg-primary-container"},
            {"error", "bg-error-container"},
            {"warning", "bg-warning-container"},
            {"neutral", "bg-surface-container-highest"}
          ] do
        assert render_component(&MdComponents.md_badge/1, tone: tone, inner_block: slot("x")) =~
                 class,
               tone
      end
    end
  end

  describe "service status badge" do
    test "failed is the error tone, processing the warning one" do
      assert render_component(&ZahlungsWeb.ServiceCorrection.status_badge/1, status: "failed") =~
               ~r/bg-error-container[^>]*>\s*Gagal/

      assert render_component(&ZahlungsWeb.ServiceCorrection.status_badge/1,
               status: "processing"
             ) =~ ~r/bg-warning-container[^>]*>\s*Diproses/
    end
  end
end
