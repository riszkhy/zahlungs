defmodule ZahlungsWeb.ReceiptController do
  use ZahlungsWeb, :controller

  alias Zahlungs.Sales

  @doc """
  Renders a standalone, print-friendly receipt page (no app layout). The page
  triggers the browser print dialog on load.
  """
  def show(conn, %{"id" => id}) do
    sale = Sales.get_sale!(id)

    conn
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:show, sale: sale)
  end
end
