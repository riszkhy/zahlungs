defmodule Zahlungs.Services.CatalogCache do
  @moduledoc """
  Keeps a vendor's catalog (SBI's price list is ~1.5 MB) in memory for a
  while, so searching it doesn't download it on every keystroke. Owns an ETS
  table; the loader runs in the caller. Nothing is written to the database.

  The lifetime is `config :zahlungs, Zahlungs.Services.CatalogCache, ttl:`
  (milliseconds, default 10 minutes; 0 in tests, so tests don't share).
  """
  use GenServer

  @table :service_catalog
  @default_ttl 10 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The catalog under `key`, from memory while fresh, else from `loader`."
  def fetch(key, loader, ttl \\ default_ttl()) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, items, loaded_at}] when now - loaded_at < ttl ->
        {:ok, items}

      _ ->
        case loader.() do
          {:ok, items} ->
            :ets.insert(@table, {key, items, now})
            {:ok, items}

          error ->
            error
        end
    end
  end

  defp default_ttl,
    do: Application.get_env(:zahlungs, __MODULE__, []) |> Keyword.get(:ttl, @default_ttl)
end
