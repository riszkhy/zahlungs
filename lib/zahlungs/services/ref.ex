defmodule Zahlungs.Services.Ref do
  @moduledoc """
  The refs Zahlungs sends to a provider (`ref_1` at SBI): a prefix (`"Z"` for
  a transaction, `"Q"` for an inquiry), the store's id, the UTC time to the
  second and six random hex digits — unique across organizations (store codes
  are not), at most 26 characters. The unique indexes have the last word.
  """

  @doc "A new ref, e.g. `Z12261021153000A1B2C3`."
  def generate(prefix, store_id, now \\ NaiveDateTime.utc_now()) when prefix in ["Z", "Q"] do
    prefix <>
      Integer.to_string(store_id) <>
      Calendar.strftime(now, "%y%m%d%H%M%S") <> Base.encode16(:crypto.strong_rand_bytes(3))
  end
end
