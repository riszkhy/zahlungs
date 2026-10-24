defmodule Zahlungs.Services.Provider.Sbi.Sign do
  @moduledoc """
  The `sign` header of a request to Smart Biller Indonesia: the url-safe
  base64 of the raw SHA-1 of
  `"R-ONE|mmid|product_code|customer_id|ref_1|pin|password"`, without padding.
  A field the request doesn't have is empty.
  """

  @doc "The signature for one request."
  def sign(mmid, product_code, customer_id, ref_1, pin, password) do
    ["R-ONE", mmid, product_code, customer_id, ref_1, pin, password]
    |> Enum.map_join("|", &to_string(&1 || ""))
    |> then(&:crypto.hash(:sha, &1))
    |> Base.url_encode64(padding: false)
  end
end
