defmodule ZahlungsWeb.ReceiptHTML do
  use ZahlungsWeb, :html

  embed_templates "receipt_html/*"

  def money(%Decimal{} = d), do: "Rp " <> Decimal.to_string(d)
  def money(other), do: "Rp #{other}"
end
