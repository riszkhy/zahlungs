defmodule ZahlungsWeb.ServiceReceiptHTML do
  use ZahlungsWeb, :html

  import ZahlungsWeb.ServiceLive.Index, only: [group_digits: 1, token_text: 1]

  alias Zahlungs.Services.TokenAnswer

  embed_templates "service_receipt_html/*"

  defp number_label(%{category: "tagihan"}), do: "ID pelanggan"
  defp number_label(%{category: "token_pln"}), do: "No. meter"
  defp number_label(_transaction), do: "Nomor tujuan"

  # What the owner check found comes first; else what the token's answer says.
  defp customer_name(transaction),
    do: transaction.customer_name || answer_part(transaction, :name)

  defp tariff(transaction),
    do: transaction.customer_details || answer_part(transaction, :tariff)

  defp kwh(transaction), do: answer_part(transaction, :kwh)

  defp answer_part(%{token_sn: token_sn}, part) do
    case TokenAnswer.parse(token_sn) do
      %{} = answer -> Map.fetch!(answer, part)
      nil -> nil
    end
  end

  # What the customer paid above the bill: the provider's admin and the shop's.
  defp admin_fee(transaction), do: Decimal.sub(transaction.price, transaction.bill_amount)

  defp cashier(%{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp cashier(%{user: %{email: email}}), do: email
  defp cashier(_transaction), do: nil

  defp status_label("success"), do: "Berhasil"
  defp status_label("failed"), do: "Gagal"
  defp status_label(_processing), do: "Diproses"
end
