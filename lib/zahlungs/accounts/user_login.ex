defmodule Zahlungs.Accounts.UserLogin do
  @moduledoc """
  One successful login and where it was made from. Append-only: an audit trail,
  never used to allow or refuse a login.

  The position comes from the browser, so it may be missing (permission denied),
  imprecise (`accuracy_m`), or faked. `distance_m` is the distance to the user's
  store when both positions are known.
  """
  use Ecto.Schema

  schema "user_logins" do
    field :latitude, :float
    field :longitude, :float
    field :accuracy_m, :float
    field :distance_m, :float
    field :ip, :string
    field :user_agent, :string

    belongs_to :user, Zahlungs.Accounts.User
    belongs_to :store, Zahlungs.Stores.Store

    timestamps(updated_at: false)
  end
end
