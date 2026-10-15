defmodule ZahlungsWeb.PageController do
  @moduledoc """
  `/`: the public landing page for a visitor. Someone who is logged in is sent
  on to the home screen, so the address still works as the way into the app.
  """
  use ZahlungsWeb, :controller

  def index(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/home")
    else
      conn
      |> put_root_layout(html: {ZahlungsWeb.Layouts, :landing})
      |> put_layout(html: false)
      |> assign(:page_title, "Zahlungs — Kasir dan stok toko dalam satu layar")
      |> render(:index)
    end
  end
end
