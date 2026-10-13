defmodule Zahlungs.Repo do
  use Ecto.Repo,
    otp_app: :zahlungs,
    adapter: Ecto.Adapters.MyXQL

  @moduledoc """
  The repository, with tenant isolation built in.

  Several owners (organizations) share this database. A query whose root table
  belongs to an owner — any schema with an `organization_id` field — is
  filtered to the **current organization** automatically, and refused outright
  when there is none. Forgetting to filter is an error, not a leak.

  The current organization is per process: `put_org_id/1` is called when a
  scope is built for a user (see `Zahlungs.Scope`), i.e. once per request or
  LiveView. The few queries that legitimately cross organizations — finding a
  user by email at login, the platform operator's pages, maintenance jobs —
  say so with `skip_org_id: true`.

  Only the root table of a query is checked. Tables reached through joins,
  subqueries or per-store data (sales, shifts, stock) are not filtered here;
  they are reached through stores, which are.
  """

  require Ecto.Query

  @org_key {__MODULE__, :org_id}

  @doc "Makes `org_id` the organization that owned-table queries in this process see."
  def put_org_id(org_id), do: Process.put(@org_key, org_id)

  @doc "The current organization id of this process, or nil."
  def get_org_id, do: Process.get(@org_key)

  @doc "The current organization id; raises when there is none."
  def org_id! do
    get_org_id() || raise "no current organization: build a Zahlungs.Scope first"
  end

  @impl true
  def default_options(_operation), do: [org_id: get_org_id()]

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      not owned?(query) ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, organization_id: ^org_id), opts}

      true ->
        raise ArgumentError,
              "query on an organization-owned table without a current organization " <>
                "(pass skip_org_id: true if it really must cross organizations): " <>
                inspect(query)
    end
  end

  defp owned?(%Ecto.Query{from: %{source: {_table, schema}}})
       when is_atom(schema) and not is_nil(schema) do
    :organization_id in schema.__schema__(:fields)
  end

  defp owned?(_query), do: false
end
