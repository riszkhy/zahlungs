defmodule ZahlungsWeb.PpobCallbackController do
  @moduledoc """
  A PPOB provider reporting a service's result.

  - `POST /api/ppob/callback/:token`: the token picks the deposit account
    (`Zahlungs.Services.handle_callback/3`).
  - `POST /api/ppob/callback`: the provider's ref picks the service, and its
    account checks the caller (`Zahlungs.Services.handle_ref_callback/2`) —
    Smart Biller Indonesia's way.

  The adapter sees the request headers plus `"x-zahlungs-client-ip"`, the
  caller's address (`ZahlungsWeb.ClientIp`), always set here so a caller
  can't send its own.

  200 for a callback applied or already applied (providers retry until they
  get one), 401 when the caller isn't believed, 404 for an unknown account or
  service.
  """
  use ZahlungsWeb, :controller

  alias Zahlungs.Services
  alias ZahlungsWeb.ClientIp

  def create(conn, %{"token" => token} = params) do
    token
    |> Services.handle_callback(Map.delete(params, "token"), headers(conn))
    |> reply(conn)
  end

  def create_by_ref(conn, params) do
    params |> Services.handle_ref_callback(headers(conn)) |> reply(conn)
  end

  defp headers(conn) do
    conn.req_headers |> Map.new() |> Map.put("x-zahlungs-client-ip", ClientIp.of(conn))
  end

  defp reply({:ok, _applied_or_final}, conn), do: json(conn, %{ok: true})

  defp reply({:error, :invalid_signature}, conn),
    do: conn |> put_status(401) |> json(%{ok: false})

  defp reply({:error, _not_found}, conn), do: conn |> put_status(404) |> json(%{ok: false})
end
