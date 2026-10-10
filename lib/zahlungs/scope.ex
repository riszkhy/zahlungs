defmodule Zahlungs.Scope do
  @moduledoc """
  Who is acting, and in which store.

  Every context function that reads or writes per-store data (stock, sales,
  shifts) takes a scope, so the store never comes from request params and a
  query can't forget to filter by it.

    * A **cashier** is bound to their own store. Without an active one they have
      no usable scope (`store: nil`) and are not let in.
    * An **admin** works in the store they picked (kept in the session), or in
      none at all — "all stores" — which reports and lists treat as no filter.
  """

  alias Zahlungs.Accounts.User
  alias Zahlungs.Stores
  alias Zahlungs.Stores.Store

  defstruct user: nil, store: nil

  @doc """
  Builds the scope for a user. `chosen` is the admin's store choice from the
  session: a store id, `"all"`, or nil for the default. It is ignored for
  cashiers.
  """
  def for_user(user, chosen \\ nil)

  def for_user(nil, _chosen), do: nil

  def for_user(%User{role: "admin"} = user, "all"), do: %__MODULE__{user: user, store: nil}

  def for_user(%User{role: "admin"} = user, chosen) do
    store =
      Stores.get_active_store(chosen) || Stores.get_active_store(user.store_id) ||
        Stores.default_store()

    %__MODULE__{user: user, store: store}
  end

  def for_user(%User{} = user, _chosen) do
    %__MODULE__{user: user, store: Stores.get_active_store(user.store_id)}
  end

  @doc "A scope for a store with no acting user (seeds, background work, tests)."
  def for_store(%Store{} = store), do: %__MODULE__{store: store}

  @doc "True when the scope's user is an admin."
  def admin?(%__MODULE__{user: %User{role: "admin"}}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "True when the scope can be used at all: it has a store, or is an admin's."
  def usable?(%__MODULE__{store: %Store{}}), do: true
  def usable?(%__MODULE__{} = scope), do: admin?(scope)
  def usable?(nil), do: false

  @doc """
  The id to filter per-store data by, or nil for an admin looking at all stores.
  Raises for a non-admin without a store, so a missing store can never widen a
  query to everything.
  """
  def store_id(%__MODULE__{store: %Store{id: id}}), do: id

  def store_id(%__MODULE__{store: nil} = scope) do
    if admin?(scope),
      do: nil,
      else: raise(ArgumentError, "scope has no store and is not an admin's")
  end
end
