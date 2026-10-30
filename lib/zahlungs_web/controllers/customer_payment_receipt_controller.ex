defmodule ZahlungsWeb.CustomerPaymentReceiptController do
  use ZahlungsWeb, :controller

  alias Zahlungs.Customers

  @doc """
  A print-friendly receipt for a repayment of a customer's credit (no app
  layout). The balances and the notes it settled are read from the customer's
  ledger, so a reprint shows them as they were at that repayment.
  """
  def show(conn, %{"id" => id}) do
    payment = Customers.get_payment!(conn.assigns.current_scope, id)

    entry =
      payment.customer
      |> Customers.ledger()
      |> Enum.find(&(&1.kind == :payment and &1.payment.id == payment.id))

    conn
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:show, payment: payment, entry: entry)
  end
end
