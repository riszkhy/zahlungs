defmodule Zahlungs.StoresFixtures do
  @moduledoc """
  Test helpers for stores and scopes.

  Per-store data needs a store, so each test gets a **default store** of its own
  (created on first use). `user_fixture/1`, `product_fixture/1` and the helpers
  below all use it unless told otherwise, which keeps a test's data apart from
  the rows already in the database.
  """

  alias Zahlungs.{Scope, Stores}

  @doc """
  An organization (active unless told otherwise). Does not make it the current
  one — use `in_org/2` or build a scope for one of its users.
  """
  def organization_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Zahlungs.Repo.insert!(
      struct(
        %Zahlungs.Organizations.Organization{name: "Org #{n}", status: "active"},
        Map.new(attrs)
      )
    )
  end

  @doc """
  The calling test's own organization, created (and made current) the first
  time it is asked for. Fixtures use it unless told otherwise.
  """
  def default_org do
    Process.get(:default_test_org) ||
      tap(organization_fixture(), fn org ->
        Process.put(:default_test_org, org)
        Zahlungs.Repo.put_org_id(org.id)
      end)
  end

  @doc "Runs `fun` with `org` as the current organization, then restores the previous one."
  def in_org(org, fun) do
    previous = Zahlungs.Repo.get_org_id()
    Zahlungs.Repo.put_org_id(org.id)

    try do
      fun.()
    after
      Zahlungs.Repo.put_org_id(previous)
    end
  end

  @doc "A store in the current organization (the test's default one unless inside `in_org/2`)."
  def store_fixture(attrs \\ %{}) do
    default_org()
    n = System.unique_integer([:positive])

    {:ok, store} =
      attrs
      |> Enum.into(%{name: "Store #{n}", code: "T" <> Integer.to_string(n, 36)})
      |> Stores.create_store()

    store
  end

  @doc "The calling test's own store, created the first time it is asked for."
  def default_store do
    Process.get(:default_test_store) ||
      in_org(default_org(), fn ->
        tap(store_fixture(), &Process.put(:default_test_store, &1))
      end)
  end

  @doc "The scope a user acts with (their store, or the default for an admin)."
  def scope(user), do: Scope.for_user(user)

  @doc "A scope for a store with no acting user — the default store unless given."
  def store_scope(store \\ nil), do: Scope.for_store(store || default_store())

  @doc "An admin's scope over all stores."
  def all_stores_scope(admin), do: Scope.for_user(admin, "all")
end
