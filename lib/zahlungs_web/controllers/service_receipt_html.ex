defmodule ZahlungsWeb.ServiceReceiptHTML do
  use ZahlungsWeb, :html

  import ZahlungsWeb.ServiceLive.Index, only: [group_digits: 1]

  embed_templates "service_receipt_html/*"

  # A token of digits only (PLN) is read out in groups of four; an SN as sent.
  defp token_text(token) do
    if token =~ ~r/^\d{12,}$/, do: group_digits(token), else: token
  end

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
