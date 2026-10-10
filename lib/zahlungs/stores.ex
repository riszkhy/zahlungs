defmodule Zahlungs.Stores do
  @moduledoc """
  The Stores context: the shop's branches.

  The catalog (products, categories, suppliers) and users are shared by all
  stores; stock, shifts and sales belong to one. Stores are never deleted, only
  deactivated, because sales and shifts keep pointing at them.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Stores.Store

  @doc "Lists all stores (active or not), ordered by name."
  def list_stores do
    Repo.all(from s in Store, order_by: s.name)
  end

  @doc "Lists the active stores, ordered by name."
  def list_active_stores do
    Repo.all(from s in Store, where: s.active == true, order_by: s.name)
  end

  @doc "Returns `{name, id}` tuples of the active stores, for select inputs."
  def store_options do
    Enum.map(list_active_stores(), &{&1.name, &1.id})
  end

  def get_store!(id), do: Repo.get!(Store, id)

  @doc "Gets an active store by id, or nil (also for a nil or unknown id)."
  def get_active_store(nil), do: nil

  def get_active_store(id) do
    Repo.one(from s in Store, where: s.id == ^id and s.active == true)
  end

  @doc "The store used when none was chosen: the oldest active one, or nil."
  def default_store do
    Repo.one(from s in Store, where: s.active == true, order_by: s.id, limit: 1)
  end

  def create_store(attrs \\ %{}) do
    %Store{}
    |> Store.changeset(attrs)
    |> Repo.insert()
  end

  def update_store(%Store{} = store, attrs) do
    store
    |> Store.changeset(attrs)
    |> Repo.update()
  end

  @doc "Activates/deactivates a store. Cashiers of an inactive store can't log in."
  def set_store_active(%Store{} = store, active) when is_boolean(active) do
    store
    |> Ecto.Changeset.change(active: active)
    |> Repo.update()
  end

  def change_store(%Store{} = store, attrs \\ %{}) do
    Store.changeset(store, attrs)
  end
end
