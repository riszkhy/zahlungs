defmodule ZahlungsWeb.StoreSelectionController do
  @moduledoc """
  The admin's store switcher: remembers in the session which store (or all of
  them) the admin is working in. Cashiers never get here — they are bound to
  their own store.
  """
  use ZahlungsWeb, :controller

  alias Zahlungs.Stores

  def update(conn, %{"store_id" => "all"} = params) do
    conn
    |> put_session(:store_id, "all")
    |> redirect(to: return_to(params))
  end

  def update(conn, %{"store_id" => store_id} = params) do
    case Stores.get_active_store(to_id(store_id)) do
      nil ->
        conn
        |> put_flash(:error, "Toko tidak ditemukan atau tidak aktif.")
        |> redirect(to: return_to(params))

      store ->
        conn
        |> put_session(:store_id, store.id)
        |> redirect(to: return_to(params))
    end
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  # Back to the page the switcher was used on — local paths only, so the form
  # can't be used to bounce someone to another site.
  defp return_to(%{"return_to" => "/" <> rest = path}) do
    if String.starts_with?(rest, "/") or String.contains?(path, ["\\", "\n", "\r"]),
      do: ~p"/home",
      else: path
  end

  defp return_to(_params), do: ~p"/home"
end
