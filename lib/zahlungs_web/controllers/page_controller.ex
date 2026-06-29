defmodule ZahlungsWeb.PageController do
  use ZahlungsWeb, :controller

  # The default Phoenix welcome page is hidden. "/" simply forwards to the
  # dashboard; unauthenticated visitors are then sent to the log in page by the
  # auth pipeline on /home.
  def index(conn, _params) do
    redirect(conn, to: ~p"/home")
  end
end
