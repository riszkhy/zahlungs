defmodule ZahlungsWeb.ReceiptController do
  use ZahlungsWeb, :controller

  alias Zahlungs.Sales

  @doc """
  Renders a standalone, print-friendly receipt page (no app layout). The page
  triggers the browser print dialog on load.
  """
  def show(conn, %{"id" => id}) do
    sale = Sales.get_sale!(conn.assigns.current_scope, id)

    conn
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:show, sale: sale, customer_balance: balance_after(sale))
  end

  # What a credit sale's customer owed right after it, from their ledger: a
  # reprint shows the figure of then, not today's.
  defp balance_after(%{customer: %Zahlungs.Customers.Customer{} = customer} = sale) do
    customer
    |> Zahlungs.Customers.ledger()
    |> Enum.find_value(&(&1.kind == :sale and &1.sale.id == sale.id and &1.balance))
  end

  defp balance_after(_sale), do: nil
end
