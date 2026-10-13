defmodule ZahlungsWeb.LoginThrottle do
  @moduledoc """
  Slows down password guessing: after too many failed logins for the same email
  from the same address, further attempts are refused until the window passes.

  Counts are kept in memory (ETS) on this node, which is enough for a single
  server; they reset on restart. Configure with
  `config :zahlungs, ZahlungsWeb.LoginThrottle, max_attempts: 5, window_seconds: 900`.

  Behind a reverse proxy the address is the proxy's unless the endpoint is set
  up to trust `x-forwarded-for`, in which case the limit is effectively per
  email — still the property that matters.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`:ok`, or `{:error, seconds}` when this email/address must wait that long."
  def check(email, ip) do
    now = now()

    case :ets.lookup(@table, key(email, ip)) do
      [{_key, count, expires_at}] when expires_at > now ->
        if count >= config(:max_attempts), do: {:error, expires_at - now}, else: :ok

      _ ->
        :ok
    end
  end

  @doc "Counts a failed attempt. The window starts at the first failure."
  def record_failure(email, ip) do
    now = now()
    key = key(email, ip)

    case :ets.lookup(@table, key) do
      [{^key, count, expires_at}] when expires_at > now ->
        :ets.insert(@table, {key, count + 1, expires_at})

      _ ->
        :ets.insert(@table, {key, 1, now + config(:window_seconds)})
    end

    :ok
  end

  @doc "Forgets the failures, after a successful login."
  def reset(email, ip) do
    :ets.delete(@table, key(email, ip))
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp key(email, ip), do: {String.downcase(String.trim(email || "")), ip}

  defp now, do: System.monotonic_time(:second)

  defp config(key) do
    defaults = [max_attempts: 5, window_seconds: 900]
    Keyword.fetch!(Keyword.merge(defaults, Application.get_env(:zahlungs, __MODULE__, [])), key)
  end
end
