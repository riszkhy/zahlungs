defmodule ZahlungsWeb.Xlsx do
  @moduledoc """
  A minimal Excel workbook (.xlsx) with one sheet, built without a library:
  an .xlsx file is a zip of a few XML parts, and Erlang ships `:zip`.

  The first row is the header, in bold. Numbers (`Decimal`, integers) are
  written as numbers, so Excel can sum and sort them; text is escaped;
  `nil` leaves the cell empty.
  """

  @doc "The workbook as a binary: `header` (a list of strings) then `rows`."
  def build(sheet_name, header, rows) do
    parts = [
      {~c"[Content_Types].xml", content_types()},
      {~c"_rels/.rels", root_rels()},
      {~c"xl/workbook.xml", workbook(sheet_name)},
      {~c"xl/_rels/workbook.xml.rels", workbook_rels()},
      {~c"xl/styles.xml", styles()},
      {~c"xl/worksheets/sheet1.xml", sheet(header, rows)}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"workbook.xlsx", parts, [:memory])
    binary
  end

  @xml ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
  @main "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  @rel "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  defp content_types do
    @xml <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
      ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
      ~s(<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>) <>
      ~s(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>) <>
      "</Types>"
  end

  defp root_rels do
    @xml <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="#{@rel}/officeDocument" Target="xl/workbook.xml"/>) <>
      "</Relationships>"
  end

  defp workbook(sheet_name) do
    # Excel allows at most 31 characters, and not all of them, in a sheet name.
    name = sheet_name |> String.replace(~r{[\[\]:*?/\\]}, " ") |> String.slice(0, 31)

    @xml <>
      ~s(<workbook xmlns="#{@main}" xmlns:r="#{@rel}">) <>
      ~s(<sheets><sheet name="#{escape(name)}" sheetId="1" r:id="rId1"/></sheets>) <>
      "</workbook>"
  end

  defp workbook_rels do
    @xml <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="#{@rel}/worksheet" Target="worksheets/sheet1.xml"/>) <>
      ~s(<Relationship Id="rId2" Type="#{@rel}/styles" Target="styles.xml"/>) <>
      "</Relationships>"
  end

  # Style 0 is the default; style 1 (font 1) is bold, for the header.
  defp styles do
    @xml <>
      ~s(<styleSheet xmlns="#{@main}">) <>
      ~s(<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>) <>
      ~s(<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>) <>
      ~s(<fills count="2"><fill><patternFill patternType="none"/></fill>) <>
      ~s(<fill><patternFill patternType="gray125"/></fill></fills>) <>
      ~s(<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>) <>
      ~s(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>) <>
      ~s(<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>) <>
      ~s(<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>) <>
      "</styleSheet>"
  end

  defp sheet(header, rows) do
    header_row = row(1, header, ~s( s="1"))

    body =
      rows
      |> Enum.with_index(2)
      |> Enum.map(fn {cells, number} -> row(number, cells, "") end)

    IO.iodata_to_binary([
      @xml,
      ~s(<worksheet xmlns="#{@main}"><sheetData>),
      header_row,
      body,
      "</sheetData></worksheet>"
    ])
  end

  defp row(number, cells, style) do
    [
      ~s(<row r="#{number}">),
      cells
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> cell("#{column(index)}#{number}", value, style) end),
      "</row>"
    ]
  end

  defp cell(_ref, nil, _style), do: []

  defp cell(ref, %Decimal{} = value, _style),
    do: ~s(<c r="#{ref}"><v>#{Decimal.to_string(value, :normal)}</v></c>)

  defp cell(ref, value, _style) when is_integer(value), do: ~s(<c r="#{ref}"><v>#{value}</v></c>)

  defp cell(ref, value, style),
    do: ~s(<c r="#{ref}" t="inlineStr"#{style}><is><t>#{escape(to_string(value))}</t></is></c>)

  # 0 → A, 25 → Z, 26 → AA, ...
  defp column(index) when index < 26, do: <<?A + index>>
  defp column(index), do: column(div(index, 26) - 1) <> column(rem(index, 26))

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
