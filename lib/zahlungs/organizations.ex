defmodule Zahlungs.Organizations do
  @moduledoc """
  The Organizations context: owners (tenants) of the SaaS.

  Anyone can sign a business up (`register/1`); it starts `pending` and its
  users can't log in until the platform operator approves it. The operator's
  functions here deliberately cross organizations (`skip_org_id: true`) — they
  are only reachable from the `/platform` pages, which require a platform
  admin.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Accounts
  alias Zahlungs.Accounts.User
  alias Zahlungs.Organizations.{Organization, Signup}
  alias Zahlungs.Stores
  alias Zahlungs.Stores.Store

  @doc """
  Stamps a new row of an owned table with the current organization (see
  `Zahlungs.Repo`). Rows that already belong to one keep it.
  """
  def put_organization(%Ecto.Changeset{} = changeset) do
    if Ecto.Changeset.get_field(changeset, :organization_id),
      do: changeset,
      else: Ecto.Changeset.put_change(changeset, :organization_id, Repo.get_org_id())
  end

  ## Sign-up

  @doc "A changeset for the public sign-up form."
  def change_signup(attrs \\ %{}), do: Signup.changeset(%Signup{}, attrs)

  @doc """
  Registers a business: the organization (pending approval), its first store
  ("Toko Utama") and the owner's account (an admin of that organization) — all
  or nothing.

  Returns `{:ok, %{organization: org, store: store, owner: user}}` or
  `{:error, changeset}` with the sign-up form's changeset.
  """
  def register(attrs) do
    changeset = Signup.changeset(%Signup{}, attrs)

    with {:ok, signup} <- Ecto.Changeset.apply_action(changeset, :insert) do
      # The new organization's rows are written as that organization, without
      # leaving it as the caller's current one.
      previous = Repo.get_org_id()

      result =
        try do
          Repo.transaction(fn -> insert_all(signup, changeset) end)
        after
          Repo.put_org_id(previous)
        end

      # After the commit, so a listener that reloads finds the new rows.
      announce(result, & &1.organization)
    end
  end

  defp insert_all(signup, changeset) do
    organization =
      %Organization{}
      |> Organization.registration_changeset(%{name: signup.business_name, phone: signup.phone})
      |> Repo.insert!()

    Repo.put_org_id(organization.id)

    {:ok, store} = Stores.create_store(%{name: "Toko Utama", code: "TU"})

    case Accounts.create_user(%{
           "name" => signup.name,
           "email" => signup.email,
           "password" => signup.password,
           "role" => "admin",
           "store_id" => store.id
         }) do
      {:ok, owner} ->
        %{organization: organization, store: store, owner: owner}

      {:error, user_changeset} ->
        Repo.rollback(Signup.copy_errors(changeset, user_changeset))
    end
  end

  ## Announcing changes

  @topic "organizations"

  @doc """
  Subscribes the calling process to `{:organizations_changed, organization_id}`,
  sent when a business signs up or an organization's status changes. The
  platform operator's page uses it to show new sign-ups as they arrive.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Zahlungs.PubSub, @topic)

  defp announce({:ok, result}, organization) do
    message = {:organizations_changed, organization.(result).id}
    Phoenix.PubSub.broadcast(Zahlungs.PubSub, @topic, message)
    {:ok, result}
  end

  defp announce(error, _organization), do: error

  ## Reading

  def get_organization!(id), do: Repo.get!(Organization, id)

  @doc "Gets an organization, or nil (also for a nil id)."
  def get_organization(nil), do: nil
  def get_organization(id), do: Repo.get(Organization, id)

  @doc """
  Lists organizations for the platform operator, newest first, each as
  `%{organization: org, owner_email: email | nil, stores: n, users: n}`.

  Options: `:status` to filter.
  """
  def list_organizations(opts \\ []) do
    organizations =
      Organization
      |> filter_status(opts[:status])
      |> order_by(desc: :inserted_at, desc: :id)
      |> Repo.all()

    ids = Enum.map(organizations, & &1.id)

    owners =
      Repo.all(
        from(u in User,
          where: u.organization_id in ^ids and u.role == "admin",
          group_by: u.organization_id,
          select: {u.organization_id, min(u.email), count(u.id)}
        ),
        skip_org_id: true
      )
      |> Map.new(fn {id, email, _admins} -> {id, email} end)

    users = count_by_org(User, ids)
    stores = count_by_org(Store, ids)

    Enum.map(organizations, fn organization ->
      %{
        organization: organization,
        owner_email: owners[organization.id],
        users: Map.get(users, organization.id, 0),
        stores: Map.get(stores, organization.id, 0)
      }
    end)
  end

  @doc """
  How many organizations are in each status, as `%{status => count}` with
  every status present. `counts["pending"]` is what waits for the operator.
  """
  def count_by_status do
    counts =
      Map.new(
        Repo.all(from o in Organization, group_by: o.status, select: {o.status, count(o.id)})
      )

    Map.new(Organization.statuses(), &{&1, Map.get(counts, &1, 0)})
  end

  defp filter_status(query, status) when status in [nil, ""], do: query
  defp filter_status(query, status), do: where(query, [o], o.status == ^status)

  defp count_by_org(schema, ids) do
    Repo.all(
      from(r in schema,
        where: r.organization_id in ^ids,
        group_by: r.organization_id,
        select: {r.organization_id, count(r.id)}
      ),
      skip_org_id: true
    )
    |> Map.new()
  end

  ## Review (platform operator)

  # pending -> active | rejected; active <-> suspended; a rejection can be undone.
  @transitions %{
    "pending" => ~w(active rejected),
    "active" => ~w(suspended),
    "suspended" => ~w(active),
    "rejected" => ~w(active)
  }

  @doc """
  Changes an organization's status, recording who did it and an optional note.
  Returns `{:error, :invalid_transition}` for a change that makes no sense
  (e.g. suspending a pending organization).
  """
  def set_status(%Organization{} = organization, status, %User{} = reviewer, note \\ nil) do
    if status in Map.get(@transitions, organization.status, []) do
      organization
      |> Organization.review_changeset(status, reviewer.id, note)
      |> Repo.update()
      |> announce(& &1)
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Records the manually agreed billing: paid-until date and a note."
  def update_billing(%Organization{} = organization, attrs) do
    organization
    |> Organization.billing_changeset(attrs)
    |> Repo.update()
  end

  def change_billing(%Organization{} = organization, attrs \\ %{}) do
    Organization.billing_changeset(organization, attrs)
  end
end
