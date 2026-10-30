defmodule ZahlungsWeb.CustomerPaymentReceiptHTML do
  use ZahlungsWeb, :html

  embed_templates "customer_payment_receipt_html/*"

  def method_label("cash"), do: "Tunai"
  def method_label("qris"), do: "QRIS"
  def method_label("card"), do: "Kartu"
  def method_label("transfer"), do: "Transfer"
  def method_label(other), do: other
end
