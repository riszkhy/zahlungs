defmodule ZahlungsWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias ZahlungsWeb.CoreComponents

  describe "format_money/1" do
    test "formats Rupiah with thousands and decimal separators" do
      assert CoreComponents.format_money(Decimal.new("3500")) == "Rp 3.500,00"
      assert CoreComponents.format_money(Decimal.new("12000.5")) == "Rp 12.000,50"
      assert CoreComponents.format_money(Decimal.new("1234567.89")) == "Rp 1.234.567,89"
    end

    test "handles integers, strings, zero and negatives" do
      assert CoreComponents.format_money(1000) == "Rp 1.000,00"
      assert CoreComponents.format_money("2500") == "Rp 2.500,00"
      assert CoreComponents.format_money(Decimal.new(0)) == "Rp 0,00"
      assert CoreComponents.format_money(Decimal.new("-2000")) == "-Rp 2.000,00"
    end
  end

  describe "pagination/1" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    defp pagination(assigns), do: render_component(&CoreComponents.pagination/1, assigns)

    # The numbered buttons and gaps, in order: [1, :gap, 4, 5, 6, :gap, 20].
    defp links(html) do
      ~r{<button[^>]*>\s*(\d+)\s*</button>|(…)}
      |> Regex.scan(html)
      |> Enum.map(fn
        [_, number] -> String.to_integer(number)
        [_, "", "…"] -> :gap
      end)
    end

    defp button(html, label) do
      [tag] = Regex.run(~r{<button[^>]*>\s*#{label}\s*</button>}, html)
      tag
    end

    # The attribute, not the `disabled:` variant in the class list.
    defp disabled?(tag), do: tag =~ ~r/\sdisabled[\s>=]/

    test "renders nothing for an empty list" do
      refute pagination(page: 1, per_page: 25, total: 0) =~ "<nav"
    end

    test "a single page shows the count without buttons" do
      html = pagination(page: 1, per_page: 25, total: 3, noun: "produk")

      assert html =~ "Menampilkan 1–3 dari 3 produk"
      refute html =~ "<button"
    end

    test "a page in the middle links to its neighbours and both ends" do
      html = pagination(page: 5, per_page: 10, total: 200, noun: "penjualan")

      assert html =~ "Menampilkan 41–50 dari 200 penjualan"
      assert links(html) == [1, :gap, 4, 5, 6, :gap, 20]
      assert button(html, "5") =~ ~s(aria-current="page")
      refute button(html, "4") =~ "aria-current"

      # JS.push sends the page as a JSON number.
      assert button(html, "Sebelumnya") =~ "&quot;to&quot;:4"
      assert button(html, "Berikutnya") =~ "&quot;to&quot;:6"
      assert button(html, "20") =~ "&quot;event&quot;:&quot;page&quot;"
    end

    test "the first and last pages disable the button that leads nowhere" do
      first = pagination(page: 1, per_page: 10, total: 195)
      assert first |> button("Sebelumnya") |> disabled?()
      refute first |> button("Berikutnya") |> disabled?()

      last = pagination(page: 20, per_page: 10, total: 195)
      assert last =~ "Menampilkan 191–195 dari 195"
      assert last |> button("Berikutnya") |> disabled?()
      refute last |> button("Sebelumnya") |> disabled?()
    end

    test "a gap never hides a single page" do
      assert links(pagination(page: 3, per_page: 10, total: 80)) == [1, 2, 3, 4, :gap, 8]
      assert links(pagination(page: 6, per_page: 10, total: 80)) == [1, :gap, 5, 6, 7, 8]
      assert links(pagination(page: 2, per_page: 10, total: 30)) == [1, 2, 3]
    end

    test "pushes the event it is given" do
      html = pagination(page: 1, per_page: 10, total: 30, event: "goto")
      assert button(html, "2") =~ "&quot;event&quot;:&quot;goto&quot;"
    end
  end
end
