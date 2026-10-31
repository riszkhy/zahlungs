defmodule ZahlungsWeb.XlsxTest do
  use ExUnit.Case, async: true

  alias ZahlungsWeb.Xlsx

  defp unzip(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  test "builds a workbook Excel can open: the parts it needs, zipped" do
    files = Xlsx.build("Produk", ["Nama"], [["A"]]) |> unzip()

    for part <- ~w([Content_Types].xml _rels/.rels xl/workbook.xml xl/_rels/workbook.xml.rels
                   xl/styles.xml xl/worksheets/sheet1.xml) do
      assert Map.has_key?(files, part), "missing #{part}"
    end

    assert files["xl/workbook.xml"] =~ ~s(name="Produk")
  end

  test "a bold header, text escaped, numbers as numbers, blanks empty" do
    sheet =
      Xlsx.build("Produk", ["Nama", "Harga"], [
        ["Pulsa <Tsel> & \"10K\"", Decimal.new("11000.50")],
        ["Token", 7],
        ["Tagihan", nil]
      ])
      |> unzip()
      |> Map.fetch!("xl/worksheets/sheet1.xml")

    assert sheet =~ ~s(<c r="A1" t="inlineStr" s="1"><is><t>Nama</t></is></c>)
    assert sheet =~ "Pulsa &lt;Tsel&gt; &amp; &quot;10K&quot;"
    assert sheet =~ ~s(<c r="B2"><v>11000.50</v></c>)
    assert sheet =~ ~s(<c r="B3"><v>7</v></c>)
    refute sheet =~ ~s(r="B4")
  end

  test "column letters go past Z" do
    row = Enum.map(1..28, &"c#{&1}")
    sheet = Xlsx.build("S", row, []) |> unzip() |> Map.fetch!("xl/worksheets/sheet1.xml")

    assert sheet =~ ~s(r="Z1")
    assert sheet =~ ~s(r="AB1")
  end
end
