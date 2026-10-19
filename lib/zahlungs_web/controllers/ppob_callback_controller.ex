defmodule ZahlungsWeb.PpobCallbackController do
  @moduledoc """
  `POST /api/ppob/callback/:token`: a PPOB provider reporting a service's
  result. The token picks the deposit account; the adapter checks the
  signature; `Zahlungs.Services.handle_callback/3` does the rest.

  200 for a callback applied or already applied (providers retry until they
  get one), 401 for a bad signature, 404 for an unknown account or service.
  """
  use ZahlungsWeb, :controller

  alias Zahlungs.Services

  def create(conn, %{"token" => token} = params) do
    headers = Map.new(conn.req_headers)

    case Services.handle_callback(token, Map.delete(params, "token"), headers) do
      {:ok, _applied_or_final} -> json(conn, %{ok: true})
      {:error, :invalid_signature} -> conn |> put_status(401) |> json(%{ok: false})
      {:error, _not_found} -> conn |> put_status(404) |> json(%{ok: false})
    end
  end
end
