defmodule ZahlungsWeb.ServiceReceiptHTML do
  use ZahlungsWeb, :html

  import ZahlungsWeb.ServiceLive.Index, only: [group_digits: 1]

  embed_templates "service_receipt_html/*"

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
