defmodule Zahlungs.Services.Provider.Sbi.StubClient do
  @moduledoc """
  Stands in for `Zahlungs.Services.Provider.Sbi.Client` in tests: no request
  ever reaches Smart Biller Indonesia. A test queues answers per action with
  `expect/2`; requests are answered in order and recorded for `requests/0`.

  Answers belong to the test process and are found from the calling process
  or its `$callers` (a `Task` started by the code under test), so async tests
  don't see each other's. `start/0` (from `test_helper.exs`) creates the table.
  """

  @table :sbi_stub_client

  @doc "Creates the shared table; called once from test_helper.exs."
  def start do
    owner =
      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set])

        receive do
          :stop -> :ok
        end
      end)

    wait_for_table()
    owner
  end

  defp wait_for_table do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(5)
      wait_for_table()
    end
  end

  @doc "Queues `answer` for the next request with `action` (`\"pricelist\"` for `get_json/2`)."
  def expect(action, answer) do
    key = {self(), action}
    queue = lookup(key)
    :ets.insert(@table, {key, queue ++ [answer]})
    :ok
  end

  @doc """
  Answers every request with `action` by `fun.(body)` once its queue is empty
  — for requests sent concurrently, whose order a queue can't follow.
  """
  def respond(action, fun) when is_function(fun, 1) do
    :ets.insert(@table, {{self(), {:responder, action}}, fun})
    :ok
  end

  @doc "The requests the test sent so far, oldest first: `{action, body, headers}`."
  def requests do
    lookup({self(), :requests})
  end

  def post(action, body, headers, _timeout) do
    answer(action, {action, body, headers})
  end

  def get_json(url, _timeout) do
    answer("pricelist", {"pricelist", url, []})
  end

  defp answer(action, {_action, body, _headers} = request) do
    chain = [self() | Process.get(:"$callers", [])]

    case Enum.find(chain, fn pid -> lookup({pid, action}) != [] end) do
      nil ->
        owner =
          Enum.find(chain, &responder(&1, action)) ||
            raise "StubClient: no answer queued for #{inspect(action)}"

        log(owner, request)
        responder(owner, action).(body)

      owner ->
        [answer | rest] = lookup({owner, action})
        :ets.insert(@table, {{owner, action}, rest})
        log(owner, request)
        answer
    end
  end

  defp responder(pid, action) do
    case :ets.lookup(@table, {pid, {:responder, action}}) do
      [{_key, fun}] -> fun
      [] -> nil
    end
  end

  # Concurrent requests of one test may log at once; the order of those is
  # not promised.
  defp log(owner, request) do
    :ets.insert(@table, {{owner, :requests}, lookup({owner, :requests}) ++ [request]})
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> []
    end
  end
end
