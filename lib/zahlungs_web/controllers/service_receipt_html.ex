defmodule ZahlungsWeb.ServiceReceiptHTML do
  use ZahlungsWeb, :html

  import ZahlungsWeb.ServiceLive.Index, only: [group_digits: 1]

  embed_templates "service_receipt_html/*"

  # A token of digits only (PLN) is read out in groups of four; an SN as sent.
  defp token_text(token) do
    if token =~ ~r/^\d{12,}$/, do: group_digits(token), else: token
  end

  defp number_label(%{category: "tagihan"}), do: "ID pelanggan"
  defp number_label(_transaction), do: "Nomor tujuan"

  # What the customer paid above the bill: the provider's admin and the shop's.
  defp admin_fee(transaction), do: Decimal.sub(transaction.price, transaction.bill_amount)

  defp cashier(%{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp cashier(%{user: %{email: email}}), do: email
  defp cashier(_transaction), do: nil

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
