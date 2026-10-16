defmodule ZahlungsWeb.ServiceReceiptController do
  use ZahlungsWeb, :controller

  alias Zahlungs.Services

  @doc """
  A print-friendly receipt for a PPOB service (no app layout), with the token
  or serial number when there is one. Another store's service is a 404.
  """
  def show(conn, %{"id" => id}) do
    transaction = Services.get_transaction!(conn.assigns.current_scope, id)

    conn
    |> put_root_layout(html: false)
    |> put_layout(html: false)
    |> render(:show, transaction: transaction)
  end
end
