defmodule Zahlungs.Scope do
  @moduledoc """
  Who is acting, for which organization, and in which store.

  Building a scope for a user also makes that user's organization the current
  one for the process (`Zahlungs.Repo.put_org_id/1`), so every query on an
  owned table that follows is confined to it. Context functions that read or
  write per-store data (stock, sales, shifts) take the scope too, so the store
  never comes from request params.

    * A **cashier** is bound to their own store. Without an active one they have
      no usable scope and are not let in.
    * An **admin** (an owner or their staff) works in the store they picked
      (kept in the session), or in none — "all stores" — which lists and
      reports treat as every store of their organization.
    * A **platform admin** (role `superadmin`) belongs to no organization and
      has no store: they only use the `/platform` pages.

  A scope is only usable while the organization is `active`.
  """

  alias Zahlungs.Accounts.User
  alias Zahlungs.Organizations
  alias Zahlungs.Organizations.Organization
  alias Zahlungs.Repo
  alias Zahlungs.Stores
  alias Zahlungs.Stores.Store

  defstruct user: nil, organization: nil, store: nil

  @doc """
  Builds the scope for a user and enters their organization. `chosen` is the
  admin's store choice from the session: a store id, `"all"`, or nil for the
  default. It is ignored for cashiers.
  """
  def for_user(user, chosen \\ nil)

  def for_user(nil, _chosen), do: nil

  def for_user(%User{role: "superadmin"} = user, _chosen) do
    Repo.put_org_id(nil)
    %__MODULE__{user: user}
  end

  def for_user(%User{} = user, chosen) do
    Repo.put_org_id(user.organization_id)

    %__MODULE__{
      user: user,
      organization: Organizations.get_organization(user.organization_id),
      store: store_for(user, chosen)
    }
  end

  defp store_for(%User{role: "admin"}, "all"), do: nil

  defp store_for(%User{role: "admin"} = user, chosen) do
    Stores.get_active_store(chosen) || Stores.get_active_store(user.store_id) ||
      Stores.default_store()
  end

  defp store_for(%User{} = user, _chosen), do: Stores.get_active_store(user.store_id)

  @doc """
  A scope for a store with no acting user (seeds, background work, tests).
  Enters the store's organization.
  """
  def for_store(%Store{} = store) do
    Repo.put_org_id(store.organization_id)
    %__MODULE__{store: store}
  end

  @doc "True when the scope's user is an admin of their organization."
  def admin?(%__MODULE__{user: %User{role: "admin"}}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "True for the platform operator."
  def platform_admin?(%__MODULE__{user: %User{role: "superadmin"}}), do: true
  def platform_admin?(_scope), do: false

  @doc """
  Why this scope can't use the application, or nil when it can:
  `:pending`, `:rejected` or `:suspended` (the organization's status),
  `:no_organization`, or `:no_store` (a cashier without an active store).
  """
  def block_reason(nil), do: :no_organization

  def block_reason(%__MODULE__{user: nil, store: %Store{}}), do: nil

  def block_reason(%__MODULE__{} = scope) do
    case scope.organization do
      nil -> :no_organization
      %Organization{status: "active"} -> if scope.store || admin?(scope), do: nil, else: :no_store
      %Organization{status: status} -> String.to_existing_atom(status)
    end
  end

  @doc "True when the scope can be used: an active organization, and a store or an admin."
  def usable?(scope), do: block_reason(scope) == nil

  @doc """
  The id to filter per-store data by, or nil for an admin looking at all the
  stores of their organization. Raises for a non-admin without a store, so a
  missing store can never widen a query.
  """
  def store_id(%__MODULE__{store: %Store{id: id}}), do: id

  def store_id(%__MODULE__{store: nil} = scope) do
    if admin?(scope),
      do: nil,
      else: raise(ArgumentError, "scope has no store and is not an admin's")
  end
end
